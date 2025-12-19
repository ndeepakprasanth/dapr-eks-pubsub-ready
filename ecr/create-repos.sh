
#!/bin/bash
set -euo pipefail

REGION=us-east-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

for REPO in productservice orderservice; do
  if ! aws ecr describe-repositories --repository-names "$REPO" --region "$REGION" >/dev/null 2>&1; then
    echo ">>> Creating ECR repo: $REPO"
    aws ecr create-repository --repository-name "$REPO" --region "$REGION" >/dev/null
  else
    echo ">>> ECR repo exists: $REPO"
  fi
done

echo ">>> ECR login"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

