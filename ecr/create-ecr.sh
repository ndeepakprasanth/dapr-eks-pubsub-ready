
#!/usr/bin/env bash
set -euo pipefail

# Usage: ./ecr/create-ecr.sh <aws_account_id> <region> <repo_prefix>
ACCID=${1:-}
REGION=${2:-us-east-1}
PREFIX=${3:-dapr-eks-pubsub}
if [[ -z "$ACCID" ]]; then echo "Provide AWS Account ID as first arg"; exit 1; fi

aws ecr create-repository --repository-name ${PREFIX}/productservice >/dev/null 2>&1 || true
aws ecr create-repository --repository-name ${PREFIX}/orderservice  >/dev/null 2>&1 || true

echo "ECR repos ensured: ${PREFIX}/productservice, ${PREFIX}/orderservice"
