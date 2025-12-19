
# Dapr on EKS with AWS SNS/SQS Pub/Sub (IRSA)

This repo gives you a **minimal, working** implementation for your Introspect 1B:

- 2 Node.js microservices:
  - **ProductService** (publisher) → publishes to topic `orders` via Dapr
  - **OrderService** (subscriber) → receives events from Dapr via declarative Subscription
- Dapr installed on EKS via Helm
- Dapr **AWS SNS/SQS** pub/sub component configured for **IRSA** (no static AWS keys)
- Docker images pushed to **Amazon ECR**
- One-click scripts to create the cluster, build/push, deploy and test

> Default region is **us-east-1**. Change in `dapr/snssqs-pubsub.yaml` and scripts if needed.

---

## 0) Prereqs

- AWS CLI, kubectl, eksctl, Helm, Docker
- Logged in to the right AWS account; `aws configure set region us-east-1`
- Node.js 20+ for local tests

## 1) Create EKS (with OIDC + IRSA service account)

```bash
# from repo root
./eks/create-cluster.sh <AWS_ACCOUNT_ID>
```

This uses `eksctl` to create a basic EKS cluster (1.29), enables **OIDC**, and creates an **IRSA** service account `dapr-pubsub-sa` in namespace `dapr-apps` with an IAM role that has SNS/SQS permissions.

## 2) Build and push images to ECR

```bash
./scripts/build_push.sh <AWS_ACCOUNT_ID> us-east-1 dapr-eks-pubsub
```

The script also replaces `<ECR_URI>` placeholders in `k8s/*` manifests.

## 3) Deploy Dapr + components + apps

```bash
./scripts/deploy.sh
```

This will:
- Install **Dapr** via Helm (namespace `dapr-system`)
- Create namespace + SA
- Apply the **AWS SNS/SQS** Dapr component and **Subscription**
- Deploy **ProductService** and **OrderService**, then publish a test event

Verify subscriber logs:
```bash
kubectl -n dapr-apps logs deploy/orderservice
```

## 4) Manual test

```bash
# Port-forward ProductService
kubectl -n dapr-apps port-forward deploy/productservice 18080:8080
# Publish a message
curl -X POST http://localhost:18080/publish   -H 'Content-Type: application/json'   -d '{"orderId": 42, "item":"book"}'
# Check OrderService logs
kubectl -n dapr-apps logs deploy/orderservice -f
```

## Deliverables mapping

- **Source code** → `src/productservice`, `src/orderservice`
- **Dockerfiles** → in each service folder
- **Images in ECR** → created by `build_push.sh`
- **Kubernetes YAML** → `k8s/*.yaml`
- **Dapr components** → `dapr/snssqs-pubsub.yaml`
- **EKS config** → `eks/eksctl-cluster.yaml`
- **Architecture diagram** → `screenshots/architecture.png` (and in README below)
- **Screenshots & Logs** → capture `kubectl logs` output after publish
- **README** → this file
- **Optional Bedrock prompts** → see bottom

## Architecture

```mermaid
flowchart LR
  subgraph AWS[EKS Cluster]
    PS[ProductService
(app + Dapr sidecar)] -- HTTP publish --> DaprPS[daprd]
    OS[OrderService
(app + Dapr sidecar)] -- subscribe --> DaprOS[daprd]
  end
  DaprPS -- publish(topic=orders) --> SNS[(Amazon SNS)]
  SNS -- fanout --> SQS[(Amazon SQS)]
  SQS -- poll/receive --> DaprOS
```

- Dapr sidecars use **IRSA** via service account `dapr-pubsub-sa` to authenticate to AWS.
- `dapr/snssqs-pubsub.yaml` sets the component `pubsub.aws.snssqs` with `region: us-east-1` and lets Dapr auto-manage SNS/SQS entities.

## Troubleshooting

- **Sidecar not injected?** Check annotations and injector logs:
  ```bash
  kubectl -n dapr-apps get pod -l app=productservice -o yaml | yq '.spec.containers[].name'
  kubectl -n dapr-system logs -l app=dapr-sidecar-injector
  ```
- **No messages?**
  - Ensure the Dapr component exists in the same namespace: `kubectl -n dapr-apps get components`
  - Check sidecar logs for pub/sub errors: `kubectl -n dapr-apps logs deploy/orderservice -c daprd`
- **ECR auth errors?** Re-run `aws ecr get-login-password ... | docker login ...`

## GenAI (Amazon Bedrock) prompts

- **Telemetry gaps**: *“Given the attached Node.js services and Kubernetes/Dapr manifests, suggest missing telemetry: custom logs, trace spans, attributes, and metrics (publish latency, delivery success/failure, dead-letter counts). Output OpenTelemetry config snippets for Node.js and K8s.”*
- **Resiliency**: *“Recommend retry/backoff/circuit-breaker policies for Dapr pub/sub (AWS SNS/SQS) and app-level idempotency handling. Include Dapr **resiliency policies** YAML and sample deduplication logic.”*
- **Artifacts review**: *“Analyze the Dockerfiles, Deployment YAML, and Dapr component; flag security/perf smells (root user, resource requests/limits, liveness probes, message concurrency). Provide fixes.”*
- **Scaling patterns**: *“For SQS + Dapr on EKS, propose horizontal pod autoscaling based on SQS queue length (KEDA) and Dapr bulkSubscribe settings for high throughput. Include manifests.”*

---

**Author**: Generated on 2025-12-18T21:05:18.977712Z
