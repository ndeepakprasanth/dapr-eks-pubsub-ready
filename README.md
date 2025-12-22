
# Dapr on EKS with AWS SNS/SQS Pub/Sub
**Author**: Deepak  
**Project**: Containerized Microservices on Amazon EKS with Dapr Sidecars

This repo provides a **complete, working** implementation of containerized microservices on Amazon EKS with Dapr sidecars for pub/sub messaging:

- 2 Node.js microservices:
  - **ProductService** (publisher) → publishes to topic `orders` via Dapr
  - **OrderService** (subscriber) → receives events from Dapr via declarative Subscription
- Dapr installed on EKS via Helm
- Dapr **AWS SNS/SQS** pub/sub component configured
- Docker images pushed to **Amazon ECR**
- One-click deployment script

> Default region is **us-east-1**. Change in scripts if needed.

---

## Prerequisites
**Author**: Deepak

- AWS CLI configured with appropriate permissions
- kubectl, eksctl, Helm 3+, Docker installed
- Node.js 20+ (for local development)
- Your AWS Account ID
- Run `./check-prerequisites.sh` to validate setup

## Quick Start

### Option 1: One-click deployment

```bash
# Set your AWS Account ID and run
ACCOUNT_ID=123456789012 ./oneclick.sh

# Or with custom AWS profile
ACCOUNT_ID=123456789012 AWS_PROFILE=YourProfile ./oneclick.sh
```

### Option 2: Step-by-step

1. **Build and push images to ECR:**
```bash
./scripts/build_push.sh <YOUR_AWS_ACCOUNT_ID>
```

2. **Deploy to EKS:**
```bash
./scripts/deploy.sh
```

## Test the deployment

```bash
# Test pub/sub functionality
kubectl -n dapr-apps run test-curl --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 -- \
  curl -X POST http://productservice:8080/publish \
    -H 'Content-Type: application/json' \
    -d '{"orderId": 123, "item":"laptop", "price": 999.99}'

# Check logs
kubectl -n dapr-apps logs deploy/orderservice --tail=10
```

## Verify deployment

```bash
# Check pods (should show 2/2 Ready)
kubectl -n dapr-apps get pods -o wide

# Check services
kubectl -n dapr-apps get svc

# Check Dapr components
kubectl -n dapr-apps get components

# View ECR repositories
aws ecr describe-repositories --region us-east-1
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

**StorageClass / Demo Mode**

- The Dapr scheduler StatefulSet requires PersistentVolumeClaims. Ensure a default StorageClass is present in your cluster so PVCs are dynamically provisioned (for example `gp2` or `ebs-gp3`).
- For quick demos or CI where provisioning EBS volumes is undesirable, set `DEMO_MODE=true` before running the installer to disable scheduler persistence:

```bash
DEMO_MODE=true ./oneclick.sh
```

The repo includes an example StorageClass at `eks/ebs-gp3-sc.yaml` that will be applied automatically by the scripts if no default StorageClass is detected.

## Project Structure
**Author**: Deepak

```
.
├── src/
│   ├── productservice/     # Publisher microservice
│   └── orderservice/       # Subscriber microservice
├── k8s/                    # Kubernetes manifests
├── dapr/                   # Dapr components
├── scripts/                # Build and deploy scripts
├── oneclick.sh            # Complete deployment script
├── test.sh                # Test script
└── README.md
```

## Assignment Deliverables ✅
**Author**: Deepak

- ✅ **Source Code** → `src/productservice`, `src/orderservice`
- ✅ **Dockerfiles** → in each service folder
- ✅ **Container Images in ECR** → created by build scripts
- ✅ **Kubernetes YAML** → `k8s/*.yaml`
- ✅ **Dapr Components** → `dapr/snssqs-pubsub.yaml`
- ✅ **EKS Deployment** → automated via scripts
- ✅ **Working Pub/Sub** → ProductService → OrderService flow
- ✅ **Screenshots & Logs** → use `./test.sh` for output

## Troubleshooting

- **ImagePullBackOff?** Run `./scripts/build_push.sh <ACCOUNT_ID>` first
- **CrashLoopBackOff?** Check architecture with `kubectl get nodes -o wide`
- **No messages?** Verify components: `kubectl -n dapr-apps get components`
- **AWS permissions?** Ensure your AWS CLI has ECR/EKS permissions