# ShopFlow, Phase 2: Operate It as a Platform

Phase 1 got the system running. Phase 2 turns it into something a real team would run in production: shipped automatically through a pipeline, monitored, secured, scalable, and packaged with Helm. You add these on top of the working Phase 1 system, one capability at a time.

`architecture.svg` in this folder shows the full production architecture, the end state you are building toward here.

## Prerequisite

Phase 1 is deployed and the order flow works. You have the EKS cluster, RDS, SQS, ECR, and the AWS Load Balancer Controller from Phase 1.

## What Phase 2 adds, and where each part lives

- **Helm packaging** (`helm/shopflow/`): the four services repackaged as one chart, now with hardened pods, resource limits, autoscaling, network policies, an IRSA service account, a Prometheus ServiceMonitor, and the secure ingress. This replaces the hand-applied manifests from Phase 1.
- **Security** (`platform/secrets/`): database credentials move to AWS Secrets Manager, pulled in by the External Secrets Operator. Pods reach SQS and secrets through IRSA, not static keys.
- **HTTPS and login** (`platform/ingress-tls-cognito/`): TLS with an ACM certificate and Cognito login enforced at the load balancer.
- **Monitoring** (`platform/monitoring/`): Prometheus, Grafana dashboards, and alerts.
- **Logging** (`platform/logging/`): all container logs shipped to CloudWatch.
- **CI/CD** (`cicd/`): each service shipped through the gated pipeline, publishing to Nexus and deploying with Helm.
- **Testing** (`testing/`): integration tests with Testcontainers, a contract-test path, and a post-deploy smoke test.

Each folder has its own SETUP.md with exact commands. Below is the order to do them in.

## Changes to carry over from Phase 1 first

Two small code changes make the Phase 2 hardening work:

1. **Metrics.** Add `io.micrometer:micrometer-registry-prometheus` (runtime scope) to each backend `pom.xml` so `/actuator/prometheus` serves metrics. See `platform/monitoring/SETUP.md`.
2. **Non-root storefront.** The hardened storefront runs as a non-root user, which cannot bind to port 80. In the Phase 1 storefront, change `nginx.conf` `listen 80;` to `listen 8080;`, and the Dockerfile base image from `nginx:1.27-alpine` to `nginxinc/nginx-unprivileged:1.27-alpine`. Rebuild and push.

## Recommended order

1. **Secrets** (`platform/secrets/SETUP.md`): create the Secrets Manager secret, install External Secrets, apply `external-secret.yaml`. Confirm the `shopflow-db` Secret appears.
2. **IRSA for the app**: create an IAM role that allows SQS access and bind it to the `shopflow` service account; put its ARN in `values.yaml` as `serviceAccount.roleArn`.
3. **Monitoring** (`platform/monitoring/SETUP.md`): install kube-prometheus-stack, apply the alert rules.
4. **Logging** (`platform/logging/SETUP.md`): install Fluent Bit.
5. **TLS and Cognito** (`platform/ingress-tls-cognito/SETUP.md`): request the certificate, create the Cognito pool, fill the `ingress` values.
6. **Deploy with Helm** (below).
7. **CI/CD** (`cicd/README.md`): wire the pipelines so future changes ship automatically.

Tip: until the certificate and Cognito values are ready, you can keep using the Phase 1 HTTP ingress and skip the chart's ingress, so you can test the rest sooner.

## Deploy with Helm

Fill in every `REPLACE_` value in `helm/shopflow/values.yaml` (registry, IRSA role ARN, RDS endpoint, certificate, Cognito). Then check the rendering before applying anything:

```bash
helm lint helm/shopflow
helm template shopflow helm/shopflow      # read the output, confirm it looks right
helm upgrade --install shopflow helm/shopflow
kubectl get pods
```

`helm template` first is the habit to build: it shows you exactly what will be applied, so you catch a wrong value before it hits the cluster.

## Verify Phase 2

- **Secrets:** `kubectl get secret shopflow-db` exists and the services start without a hand-made secret.
- **Monitoring:** the Grafana dashboard shows traffic after you place orders; an alert fires if you scale a service to zero.
- **Autoscaling:** `kubectl get hpa` shows targets; under load the replica count rises.
- **Security:** the site is reachable only over HTTPS and redirects to Cognito login; network policies block traffic that should not exist.
- **CI/CD:** a push builds, gates, publishes to Nexus, and deploys through Helm on its own.

## Cost and teardown

This runs everything Phase 1 did, plus the monitoring stack and more. The cost is real. To tear down: `helm uninstall shopflow`, uninstall the add-on Helm releases (monitoring, logging, external-secrets), delete the Ingress so the load balancer goes away, then `terraform destroy` in the Phase 1 `infra/` folder.

## A note on what could not be tested here

This package was written carefully, but the TLS, Cognito, Secrets Manager, IRSA, and monitoring pieces are specific to your AWS account and domain, and the Helm templates need your real values. Always run `helm lint` and `helm template` before installing, complete one SETUP.md at a time, and verify each before moving on. The errors you fix here are real platform-engineering work, and good interview material.

## The full story you can now tell

With both phases done, ShopFlow is a complete portfolio project: a microservices system on AWS EKS, with a React storefront and Spring Boot services communicating over REST and SQS, backed by RDS, fronted by an ALB with TLS and Cognito, secrets in Secrets Manager via IRSA, shipped through a gated Jenkins pipeline with Nexus and scanning, observed with Prometheus, Grafana, and central logging, autoscaled, network-segmented, and packaged with Helm and Terraform. That is a system you built, can draw, and can explain end to end.
