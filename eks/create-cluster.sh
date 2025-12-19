
#!/usr/bin/env bash
set -euo pipefail

# Usage: ./eks/create-cluster.sh <aws_account_id>
ACCID=${1:-}
if [[ -z "$ACCID" ]]; then echo "Provide AWS Account ID as first arg"; exit 1; fi

export AWS_ACCOUNT_ID=$ACCID

# 1) Create IAM policy for SNS/SQS if not exists
if ! aws iam get-policy --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/dapr-snssqs-access >/dev/null 2>&1; then
  aws iam create-policy --policy-name dapr-snssqs-access --policy-document file://eks/irsa-policy.json >/dev/null
fi

# 2) Create cluster with eksctl (OIDC + IRSA SA included)
eksctl create cluster -f eks/eksctl-cluster.yaml

echo "Cluster created."
