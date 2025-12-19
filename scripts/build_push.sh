
#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/build_push.sh <aws_account_id> <region> <repo_prefix>
# Example: ./scripts/build_push.sh 123456789012 us-east-1 dapr-eks-pubsub

ACCID=${1:-}
REGION=${2:-us-east-1}
PREFIX=${3:-dapr-eks-pubsub}
if [[ -z "$ACCID" ]]; then echo "Provide AWS Account ID as first arg"; exit 1; fi

ECR="${ACCID}.dkr.ecr.${REGION}.amazonaws.com"

# Create repos if not exist
aws ecr describe-repositories --repository-names ${PREFIX}/productservice >/dev/null 2>&1 || aws ecr create-repository --repository-name ${PREFIX}/productservice >/dev/null
aws ecr describe-repositories --repository-names ${PREFIX}/orderservice  >/dev/null 2>&1 || aws ecr create-repository --repository-name ${PREFIX}/orderservice >/dev/null

# Login to ECR
aws ecr get-login-password --region ${REGION} | docker login --username AWS --password-stdin ${ECR}

# Build & push ProductService
pushd src/productservice
  docker build -t ${ECR}/${PREFIX}/productservice:latest .
  docker push ${ECR}/${PREFIX}/productservice:latest
popd

# Build & push OrderService
pushd src/orderservice
  docker build -t ${ECR}/${PREFIX}/orderservice:latest .
  docker push ${ECR}/${PREFIX}/orderservice:latest
popd

# Replace placeholder in k8s manifests
sed -i.bak "s#<ECR_URI>#${ECR}/${PREFIX}#g" k8s/10-productservice.yaml k8s/11-orderservice.yaml || true

echo "Images pushed and manifests updated with ECR URI ${ECR}/${PREFIX}"
