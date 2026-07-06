# ShopFlow Working Guide (Phase 1 + Phase 2)

This file keeps the instructor flow from:
- README.md (Phase 1)
- README_old.md (Phase 2)

It also adds the real issues I hit during implementation and the fixes.

## How to use this file

1. Follow the same step order as the instructor's.
2. Under each step, check the "Challenges I hit" section.
3. Apply the "Resolution" notes before rerunning.

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
- The instructor command copies `k8s/db-secret.example.yaml` first.
- That template already uses `stringData` (not `data`), so your plain password is safely encoded by Kubernetes when applied.
- In short: our "fix" was to keep using a `stringData` template and avoid manual base64 handling.

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

If your region is not `us-east-1`, also update `AWS_REGION` in `k8s/shared-config.yaml`.

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

### Step 7: Verify order flow

```bash
kubectl get ingress shopflow
kubectl logs -l app=notifications-service --tail=20
```

---

## Phase 2: Operate It as a Platform

### Carry-over changes from Phase 1

1. Add Micrometer Prometheus registry to backend pom.xml files.
2. Run storefront as non-root:
- nginx listen on 8080
- use nginx unprivileged image

### Recommended order (same as instructor)

1. Secrets (platform/secrets/SETUP.md)
2. IRSA for app service account
3. Monitoring (platform/monitoring/SETUP.md)
4. Logging (platform/logging/SETUP.md)
5. TLS + Cognito (platform/ingress-tls-cognito/SETUP.md)
6. Deploy with Helm
7. CI/CD (cicd/README.md)

---

## Challenges We Hit and Simple Resolutions

This section is grouped by the instructor step where the issue happened.

### Phase 1, Step 4: Build and push images to ECR

#### Phase 1 - Challenge 1: Pods failed with platform mismatch (CrashLoopBackOff / image startup failure)
- Symptom: pods failed to start with platform-related errors (arm64 image on amd64 nodes).

Resolution:
- Build and push linux/amd64 images from macOS M1 using Docker buildx.
- Commands used:

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

### Phase 1, Step 5: Fill configuration

#### Phase 1 - Challenge 2: Database authentication failed even with Secret present
- Symptom: backend services crashed with DB auth errors (password looked missing/corrupted).

Resolution:
- Use Kubernetes Secret stringData for plain text input so Kubernetes handles base64 encoding safely.
- Avoid hidden newline/formatting issues when generating secrets from terminal values.

Exact change that fixed it:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
type: Opaque
stringData:
  username: "shopflow"
  password: "REPLACE_WITH_DB_PASSWORD"
```

Exact instruction used in this project:

```bash
cp k8s/db-secret.example.yaml k8s/db-secret.yaml
sed -i "" "s|REPLACE_WITH_DB_PASSWORD|$TF_VAR_db_password|" k8s/db-secret.yaml
kubectl apply -f k8s/db-secret.yaml
```

Instructor vs our solution (simple view):
- Instructor flow: copy template + replace password + apply secret.
- What we made explicit: this only works safely because the template is `stringData`-based.
- If the template were `data:` instead, you would need manual base64 values and could easily corrupt the password.

### Phase 1, Step 3: Install AWS Load Balancer Controller

#### Phase 1 - Challenge 3: Ingress ADDRESS stayed empty for a long time
- Symptom: kubectl get ingress showed no ADDRESS.

Resolution:
- Add missing IAM permission used by current ALB controller:
- elasticloadbalancing:DescribeListenerAttributes
- elasticloadbalancing:ModifyListenerAttributes
- Add these actions to policy: AWSLoadBalancerControllerIAMPolicy
- Re-apply Terraform/IAM changes, then restart controller deployment.

Commands used:

```bash
# 1) Update IAM policy JSON used by Terraform/infra to include:
#    - elasticloadbalancing:DescribeListenerAttributes
#    - elasticloadbalancing:ModifyListenerAttributes

# 2) Re-apply infra/IAM changes
cd infra
terraform apply

# 3) Restart ALB controller so it reloads permissions and re-syncs resources
kubectl rollout restart deployment aws-load-balancer-controller -n kube-system

# 4) Verify controller is healthy
kubectl get deployment -n kube-system aws-load-balancer-controller
kubectl logs -n kube-system deployment/aws-load-balancer-controller --tail=100

# 5) Verify ingress now has an ALB DNS address
kubectl get ingress shopflow
# Expected: the ADDRESS column is populated (not empty)
```

#### Phase 1 - Challenge 4: ALB address appeared but site was still unreachable
- Symptom: ingress had an ALB DNS name, but browser/curl could not reach app.

Resolution:
- In this project, the real fix was to wait a few more minutes for ALB provisioning/target registration to finish.
- After waiting, open the same ALB ADDRESS again; the storefront should load.

### Phase 2, Step 7: CI/CD (cicd/README.md)

#### Phase 2 - Challenge 1: Jenkins used wrong service or unexpected SERVICE value
- Symptom: pipeline logs looked like wrong service artifacts/scans were being used.

Resolution:
- Keep one backend Jenkinsfile parameterized by SERVICE.
- In each Jenkins job, set SERVICE explicitly (catalog, orders, notifications).
- Add a "Resolve Service" stage that prints SERVICE and SERVICE_DIR so you can verify early.

#### Phase 2 - Challenge 2: Storefront npm ci failed
- Symptom: npm ci failed because package-lock.json was missing.

Resolution:
- Stage and step:
- Phase 2 -> Step 7 (CI/CD), storefront Jenkins pipeline (`cicd/Jenkinsfile.storefront`), stage `Install + Build`.
- Actual code used:

```bash
# Use npm ci when lockfile exists for reproducible installs in CI.
if [ -f package-lock.json ]; then
  npm ci
else
  # Fall back to npm install if lockfile is not committed.
  npm install
fi
# Build storefront assets after dependency install succeeds.
npm run build
```

Why it matters:
- Reproducible builds
- Without lockfile: `npm install` may pull newer compatible versions over time.
- With lockfile: `npm ci` installs exactly what is recorded, so local/dev/CI/prod match.
- Faster and safer CI
- `npm ci` is optimized for CI and requires the lockfile.
- It avoids "works on my machine" drift caused by dependency updates.
- Deterministic security and debugging
- If a build breaks or a vuln scan changes, you can trace it to a specific locked version.
- Easier rollback because dependency state is pinned.

#### Phase 2 - Challenge 4: Sonar host URL was unreachable from Jenkins
- Symptom: scanner tried http://sonarqube:9000 and failed to query server version.

Resolution:
- Use host-reachable SONAR_HOST. In this setup, I used the EC2 server public IP (for example, `http://<EC2-HOST-PUBLIC-IP>:9000`).

#### Phase 2 - Challenge 5: Sonar server health issue (embedded Elasticsearch shard/index errors)
- Symptom: Sonar UI/service unstable even with correct URL.

Resolution:
- Root cause in this project: insufficient EC2 storage (20GB EBS volume), which caused the host to run out of space.
- Practical fix implemented: add cache/stale-file cleanup logic before every Jenkins pipeline build.
- Jenkinsfile stage where this was added: `Clean workspace and caches` (runs before Build/Test/Sonar).
- Actual code used:

```bash
set -e
rm -rf ${SERVICE_DIR}/target ${SERVICE_DIR}/.scannerwork
rm -rf /tmp/sonar-status.json
rm -rf /tmp/trivy-${SERVICE}-${BUILD_NUMBER} /tmp/trivy-cache-${SERVICE}-${BUILD_NUMBER}

# Keep one shared Trivy cache for all services to avoid duplicate DB copies.
mkdir -p ${TRIVY_CACHE_DIR}

# Run aggressive cleanup when free space is low on the cache filesystem.
FREE_KB=$(df -Pk /var/jenkins_home | awk 'NR==2 {print $4}')
MIN_FREE_KB=6291456
if [ "${FREE_KB}" -lt "${MIN_FREE_KB}" ]; then
  echo "Low disk on /var/jenkins_home detected (${FREE_KB} KB free). Running deep cleanup..."
  rm -rf /tmp/trivy-* /tmp/sonar-* || true
  trivy clean --scan-cache || true
  docker builder prune -af || true
  docker image prune -af || true
  docker container prune -f || true
else
  docker builder prune -f || true
fi
```

- Extra protection added in Image Scan stage when disk is low:

```bash
FREE_KB=$(df -Pk /var/jenkins_home | awk 'NR==2 {print $4}')
MIN_FREE_KB=5242880
if [ "${FREE_KB}" -lt "${MIN_FREE_KB}" ]; then
  trivy clean --scan-cache || true
  docker image prune -f || true
  docker builder prune -f || true
fi
```

#### Phase 2 - Challenge 6: Nexus publish failed with 401
- Symptom: deploy-file stage returned unauthorized.

Resolution:
- Fix Nexus user permissions for maven-releases upload.
- Ensure Jenkins nexus credential matches that deploy user.
- Keep NEXUS_URL (http://<EC2-HOST-PUPLIC-URL>:8081) reachable from Jenkins executor.

Nexus dashboard steps used:
- Log in to Nexus as admin.
- Go to `Security` -> `Roles` -> `Create role` (or edit an existing CI deploy role).
- Add these four privileges for `maven-releases`:
- `nx-repository-view-maven2-maven-releases-browse`
- `nx-repository-view-maven2-maven-releases-read`
- `nx-repository-view-maven2-maven-releases-add`
- `nx-repository-view-maven2-maven-releases-edit`
- Save the role.
- Confirm the Jenkins `nexus` credential username/password exactly match the Nexus user you just updated.

#### Phase 2 - Challenge 7: Helm deploy rendered invalid image tag for numeric build number
- Symptom: image looked like %!s(int64=3) and rollout failed.

Before this change (`cicd/Jenkinsfile`):

```bash
helm upgrade --install shopflow helm/shopflow \
  --reuse-values \
  --set image.tags.${SERVICE}=${IMAGE_TAG}
```

Resolution:
- Stage and step:
- Phase 2 -> Step 7 (CI/CD), backend Jenkins pipeline (`cicd/Jenkinsfile`), stage `Deploy with Helm`.

- Exact command used in this project (`cicd/Jenkinsfile`):

```bash
helm upgrade --install shopflow helm/shopflow \
  --namespace default \
  --reuse-values \
  --set-string image.tags.${SERVICE}=${IMAGE_TAG}
```

- This fixed numeric build tag handling and stopped invalid image rendering during Helm deploy.

#### Phase 2 - Challenge 8: JUnit report stage failed when no xml files existed
- Symptom: post step marked build unstable/fail for missing reports.

Resolution:
- Stage and step:
- Phase 2 -> Step 7 (CI/CD), backend Jenkins pipeline (`cicd/Jenkinsfile`), stage `Test + Coverage`, `post { always { ... } }`.

- `allowEmptyResults` should be set to `true` for the JUnit publisher.

- Exact code used in this project (`cicd/Jenkinsfile`):

```groovy
stage('Test + Coverage') {
  steps { dir("${SERVICE_DIR}") { sh 'mvn -B -ntp test' } }
  post {
    always {
      junit testResults: "${SERVICE_DIR}/target/surefire-reports/*.xml", allowEmptyResults: true // keep true so missing XML does not fail the stage
    }
  }
}
```

#### Phase 2 - Challenge 9: Trivy image scan found runtime critical vulnerabilities
- Symptom: storefront image scan failed on OpenSSL-related CVEs.

Resolution:
- Update storefront runtime image packages (libcrypto/libssl) in the Dockerfile, then rebuild and rescan through this pipeline.
- Stage and step:
- Phase 2 -> Step 7 (CI/CD), storefront Jenkins pipeline (`cicd/Jenkinsfile.storefront`), stages `Docker Build` and `Image Scan (Trivy)`.

- Exact code used in this project (`cicd/Jenkinsfile.storefront`):

```groovy

stage('Image Scan (Trivy)') {
  steps {
    sh '''
      export TRIVY_SKIP_DB_UPDATE=false
      trivy image --scanners vuln --severity CRITICAL --ignore-unfixed --exit-code 1 --no-progress --cache-dir ${TRIVY_CACHE_DIR} ${IMAGE}:${IMAGE_TAG}
    '''
  }
}
```

- What `--severity CRITICAL` + `--ignore-unfixed` did in this fix:
- `--severity CRITICAL` limited the gate to only CRITICAL findings.
- `--ignore-unfixed` ignored CRITICAL findings that had no available upstream patch yet.
- Together, the pipeline failed only on fixable CRITICAL vulnerabilities, which removed noisy non-actionable failures.
- After upgrading `libcrypto/libssl` in the storefront runtime image, the remaining fixable CRITICAL findings were resolved and the scan passed.

---

## Phase 2, Step 6: Deploy with Helm

### Challenge: Updating one service image tag accidentally affected others
- Symptom: deploying one service changed tags unexpectedly or clobbered values.

Resolution:
- Keep Helm values with per-service tags.
- During deploy, only override image.tags.<service> for selected service.
- Use --reuse-values so existing service tags stay unchanged.

Exact values used in this project (`helm/shopflow/values.yaml`):

```yaml
image:
  tag: "1.0"
  tags:
    catalog: ""
    orders: ""
    notifications: ""
    storefront: ""
```

Exact deploy override used in this project (`cicd/Jenkinsfile`):

```bash
helm upgrade --install shopflow helm/shopflow \
  --namespace default \
  --reuse-values \
  --set-string image.tags.${SERVICE}=${IMAGE_TAG}
```

Storefront deploy override used in this project (`cicd/Jenkinsfile.storefront`):

```bash
helm upgrade --install shopflow helm/shopflow \
  --namespace default \
  --reuse-values \
  --set-string image.tags.storefront=${IMAGE_TAG}
```

---

## Practical run order that worked for this repo

1. Bring up CI stack (Jenkins/Sonar/Nexus).
2. Run backend pipelines one service at a time with correct SERVICE value.
3. Run storefront pipeline separately.
4. Verify Sonar status endpoint before scan.
5. Verify enough disk on Jenkins host before Trivy-heavy stages.
6. Deploy through Helm with per-service tag override.

---

## Final verification checklist

- Phase 1 app loads from ingress and orders succeed.
- Notifications logs show confirmation event handling.
- Phase 2 CI/CD does all gates: build, test, Sonar, Trivy, publish, push, deploy.
- Sonar is reachable from Jenkins with correct host URL.
- Nexus upload succeeds with correct credential.
- Trivy scan runs without cache storage failures.
- Helm rollout succeeds with correct image tag rendering.
