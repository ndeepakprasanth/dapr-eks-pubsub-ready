
#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/build_push.sh <aws_account_id> [region] [repo_prefix]
# Example: ./scripts/build_push.sh 123456789012 us-east-1

ACCID=${1:-}
REGION=${2:-us-east-1}
PREFIX=${3:-}
if [[ -z "$ACCID" ]]; then echo "Provide AWS Account ID as first arg"; exit 1; fi

ECR="${ACCID}.dkr.ecr.${REGION}.amazonaws.com"

# Create repos if not exist (flat names)
aws ecr describe-repositories --repository-names productservice --profile Deepak >/dev/null 2>&1 || aws ecr create-repository --repository-name productservice --profile Deepak >/dev/null
aws ecr describe-repositories --repository-names orderservice --profile Deepak  >/dev/null 2>&1 || aws ecr create-repository --repository-name orderservice --profile Deepak >/dev/null

# Login to ECR
aws ecr get-login-password --region ${REGION} --profile Deepak | docker login --username AWS --password-stdin ${ECR}

# Detect platform
PLATFORM="linux/amd64"
if command -v kubectl >/dev/null 2>&1; then
  NODE_ARCH="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || true)"
  if [[ "$NODE_ARCH" == "arm64" || "$NODE_ARCH" == "aarch64" ]]; then PLATFORM="linux/arm64"; fi
fi
echo "Building for platform: $PLATFORM"

# Build & push ProductService
pushd src/productservice
  docker buildx build --platform $PLATFORM -t ${ECR}/productservice:latest . --push
popd

# Build & push OrderService
pushd src/orderservice
  docker buildx build --platform $PLATFORM -t ${ECR}/orderservice:latest . --push
popd

# Replace placeholder in k8s manifests
sed -i.bak "s#<ECR_URI>#${ECR}#g" k8s/10-productservice.yaml k8s/11-orderservice.yaml || true

echo "Images pushed and manifests updated with ECR URI ${ECR}"
