# ShopFlow Working Guide (Phase 1 + Phase 2)

This file contains the real issues I hit during implementation and the fixes.

## How to use this file

1. Follow the same step order as is in this document.
2. After each step, read the short "If this step fails" block before rerunning.
3. Use the short reference section at the end for cross-cutting issues that show up more than once.

---

## Phase 1: Build and Run the System

### Step 1: Create AWS environment with Terraform

```bash
cd infra
export TF_VAR_db_password=''   # write your own strong password here
terraform init
terraform apply
terraform output
```

### Step 2: Connect kubectl to EKS

```bash
aws eks update-kubeconfig --region us-east-1 --name shopflow
kubectl get nodes
```

### Step 3: Install AWS Load Balancer Controller

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

eksctl utils associate-iam-oidc-provider --cluster shopflow --region us-east-1 --approve

curl -fsSL -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.2/docs/install/iam_policy.json
aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file://iam-policy.json || true

eksctl create iamserviceaccount \
  --cluster shopflow --region us-east-1 \
  --namespace kube-system --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::$ACCOUNT:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve --role-name AmazonEKSLoadBalancerControllerRole

helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=shopflow \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

kubectl get deployment -n kube-system aws-load-balancer-controller
```

If this step fails:
- If `kubectl get ingress` shows no address for a long time, the ALB controller often needs more IAM permissions.
- Add these actions to the policy used by the controller:
  - `elasticloadbalancing:DescribeListenerAttributes`
  - `elasticloadbalancing:ModifyListenerAttributes`
- Re-apply Terraform/IAM changes, restart the controller, and verify the deployment again.

```bash
cd infra
terraform apply
kubectl rollout restart deployment aws-load-balancer-controller -n kube-system
kubectl get deployment -n kube-system aws-load-balancer-controller
kubectl logs -n kube-system deployment/aws-load-balancer-controller --tail=100
```

### Step 4: Build and push images to ECR

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1
REGISTRY=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com

aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $REGISTRY

for svc in catalog orders notifications; do
  docker build -t $REGISTRY/shopflow-$svc:1.0 services/$svc-service
  docker push $REGISTRY/shopflow-$svc:1.0
done

docker build -t $REGISTRY/shopflow-storefront:1.0 storefront
docker push $REGISTRY/shopflow-storefront:1.0
```

If this step fails:
- If your pods crash with platform mismatch errors, rebuild the images for `linux/amd64` from macOS.

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1
REGISTRY=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com

aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $REGISTRY

for svc in catalog orders notifications; do
  docker buildx build --platform linux/amd64 \
    -t $REGISTRY/shopflow-$svc:1.0 \
    services/$svc-service \
    --push
done

docker buildx build --platform linux/amd64 \
  -t $REGISTRY/shopflow-storefront:1.0 \
  storefront \
  --push
```

### Step 5: Fill configuration

Point the config to your database, create the DB password secret, and replace image placeholders.

```bash
# 1. database host into the ConfigMap
RDS=$(cd infra && terraform output -raw rds_endpoint | cut -d: -f1)
sed -i "s|REPLACE_RDS_ENDPOINT|$RDS|" k8s/shared-config.yaml

# 2. the database password Secret
cp k8s/db-secret.example.yaml k8s/db-secret.yaml
sed -i "s|REPLACE_WITH_DB_PASSWORD|$TF_VAR_db_password|" k8s/db-secret.yaml

# 3. image names into the deployments
sed -i "s|REPLACE_CATALOG_IMAGE|$REGISTRY/shopflow-catalog:1.0|"             k8s/catalog.yaml
sed -i "s|REPLACE_ORDERS_IMAGE|$REGISTRY/shopflow-orders:1.0|"               k8s/orders.yaml
sed -i "s|REPLACE_NOTIFICATIONS_IMAGE|$REGISTRY/shopflow-notifications:1.0|" k8s/notifications.yaml
sed -i "s|REPLACE_STOREFRONT_IMAGE|$REGISTRY/shopflow-storefront:1.0|"       k8s/storefront.yaml
```

Why this works:
- The command copies `k8s/db-secret.example.yaml` first.
- That template already uses `stringData` (not `data`), so your plain password is safely encoded by Kubernetes when applied.
- In short: the safe fix is to keep using a `stringData` template and avoid manual base64 handling.

macOS `sed` variant used in this project:

```bash
# 1. database host into the ConfigMap
RDS=$(cd infra && terraform output -raw rds_endpoint | cut -d: -f1)
sed -i "" "s|REPLACE_RDS_ENDPOINT|$RDS|" k8s/shared-config.yaml

# 2. the database password Secret
cp k8s/db-secret.example.yaml k8s/db-secret.yaml
sed -i "" "s|REPLACE_WITH_DB_PASSWORD|$TF_VAR_db_password|" k8s/db-secret.yaml

# 3. image names into the deployments
sed -i "" "s|REPLACE_CATALOG_IMAGE|$REGISTRY/shopflow-catalog:1.0|"             k8s/catalog.yaml
sed -i "" "s|REPLACE_ORDERS_IMAGE|$REGISTRY/shopflow-orders:1.0|"               k8s/orders.yaml
sed -i "" "s|REPLACE_NOTIFICATIONS_IMAGE|$REGISTRY/shopflow-notifications:1.0|" k8s/notifications.yaml
sed -i "" "s|REPLACE_STOREFRONT_IMAGE|$REGISTRY/shopflow-storefront:1.0|"       k8s/storefront.yaml
```

If this step fails:
- If the backend pods crash with DB authentication errors, the secret is usually the culprit.
- Use the `stringData`-based template and apply it as shown above.
- If your region is not `us-east-1`, also update `AWS_REGION` in `k8s/shared-config.yaml`.

### Step 6: Deploy manifests

```bash
kubectl apply -f k8s/shared-config.yaml
kubectl apply -f k8s/db-secret.yaml
kubectl apply -f k8s/catalog.yaml
kubectl apply -f k8s/orders.yaml
kubectl apply -f k8s/notifications.yaml
kubectl apply -f k8s/storefront.yaml
kubectl apply -f k8s/ingress.yaml
kubectl get pods
```

If this step fails:
- Check the pod states first, then inspect logs for the failing service.

```bash
kubectl get pods
kubectl describe pod -l app=catalog-service
kubectl logs -l app=notifications-service --tail=50
```

### Step 7: Verify order flow

```bash
kubectl get ingress shopflow
kubectl logs -l app=notifications-service --tail=20
```

If this step fails:
- If the ingress has no address yet, wait a few more minutes for the ALB and target registration to complete.
- After that, re-run the same check and verify the storefront loads in the browser.

---

## Phase 2: Operate It as a Platform

### Carry-over changes from Phase 1

1. Add Micrometer Prometheus registry to backend `pom.xml` files.
2. Run storefront as non-root:
- nginx listens on port `8080`
- use an unprivileged nginx image

### Recommended order (same as original)

1. **Secrets** (`platform/secrets/SETUP.md`): create the Secrets Manager secret, install External Secrets, apply `external-secret.yaml`. Confirm the `shopflow-db` Secret appears.
2. **IRSA for the app**: create an IAM role that allows SQS access and bind it to the `shopflow` service account; put its ARN in `values.yaml` as `serviceAccount.roleArn`.
3. **Monitoring** (`platform/monitoring/SETUP.md`): install kube-prometheus-stack, apply the alert rules.
4. **Logging** (`platform/logging/SETUP.md`): install Fluent Bit.
5. **TLS and Cognito** (`platform/ingress-tls-cognito/SETUP.md`): request the certificate, create the Cognito pool, fill the `ingress` values.
6. **Deploy with Helm** (below).
7. **CI/CD** (`cicd/README.md`): wire the pipelines so future changes ship automatically.

### Step 6: Deploy with Helm

Use Helm to deploy the platform after the supporting services are in place.

```bash
helm upgrade --install shopflow helm/shopflow \
  --namespace default \
  --reuse-values
```

If this step fails:
- Keep per-service image tags separate in Helm values.
- When deploying one service, override only that service tag.

```bash
helm upgrade --install shopflow helm/shopflow \
  --namespace default \
  --reuse-values \
  --set-string image.tags.${SERVICE}=${IMAGE_TAG}
```

### Step 7: CI/CD

Run the backend pipelines one service at a time, then run the storefront pipeline separately.

If this step fails:
- If the pipeline uses the wrong service, verify that `SERVICE` is set explicitly for each job.
- If `npm ci` fails, make sure the storefront repo has a lockfile or fall back to `npm install`.
- If Sonar cannot reach the server, point `SONAR_HOST` at a host-reachable URL such as the EC2 public IP.
- If Trivy or Sonar fail due to disk pressure, clean caches and temporary files before the build.
- If Nexus upload returns `401`, verify the repository permissions and the Jenkins credential mapping.
- If Helm renders an invalid image tag, use `--set-string` instead of `--set` for numeric build numbers.

```bash
# Example storefront fallback for CI
if [ -f package-lock.json ]; then
  npm ci
else
  npm install
fi
npm run build
```

---

## Quick reference: cross-cutting issues

- Platform mismatch: rebuild images as `linux/amd64` when deploying to amd64 EKS nodes.
- Secret encoding: keep using `stringData` for the DB password secret.
- ALB controller: add the missing listener-attribute IAM permissions and restart the controller.
- Sonar/Nexus/Trivy: verify host reachability, credentials, and enough disk space before running CI jobs.
- Helm deploys: use per-service tag overrides and `--set-string` for numeric image tags.

---

## Practical run order that worked for this repo

1. Bring up the CI stack (Jenkins, Sonar, Nexus).
2. Run backend pipelines one service at a time with the correct `SERVICE` value.
3. Run the storefront pipeline separately.
4. Verify Sonar reachability and disk space before scanning.
5. Deploy through Helm with per-service tag overrides.

---

## Final verification checklist

- Phase 1 app loads from ingress and orders succeed.
- Notifications logs show confirmation event handling.
- Phase 2 CI/CD runs build, test, Sonar, Trivy, publish, push, and deploy.
- Sonar is reachable from Jenkins with the correct host URL.
- Nexus upload succeeds with the correct credential.
- Trivy scan runs without cache storage failures.
- Helm rollout succeeds with the correct image tag rendering.
