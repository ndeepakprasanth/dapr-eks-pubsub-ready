
#!/usr/bin/env bash
set -euo pipefail

############################################
# CONFIG — change if you need to
############################################
CLUSTER_NAME="${CLUSTER_NAME:-introspect-cluster}"
REGION="${REGION:-us-east-1}"
K8S_VERSION="${K8S_VERSION:-1.33}"            # future-friendly; change to 1.29 if needed
NODE_INSTANCE_TYPE="${NODE_INSTANCE_TYPE:-t3.medium}"
DESIRED_CAPACITY="${DESIRED_CAPACITY:-2}"

# App ports & start command (override if your app uses a different port or entrypoint)
APP_PORT="${APP_PORT:-8080}"
APP_START_CMD="${APP_START_CMD:-npm start --silent}"   # if your package.json lacks "start", set: node server.js

# Paths (relative to repo root)
EKS_DIR="eks"
ECR_DIR="ecr"
DAPR_DIR="dapr"
K8S_DIR="k8s"
SRC_PRODUCT="src/productservice"
SRC_ORDER="src/orderservice"

############################################
# PRECHECKS
############################################
echo ">>> Pre-checks"
for cmd in aws eksctl kubectl helm docker; do
  command -v "$cmd" >/dev/null || { echo "Missing $cmd. Please install and retry."; exit 1; }
done
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$REGION}"
export AWS_DEFAULT_REGION

mkdir -p "$EKS_DIR" "$ECR_DIR" "$DAPR_DIR" "$K8S_DIR"

############################################
# WRITE eksctl CLUSTER CONFIG
############################################
cat > "$EKS_DIR/eksctl-cluster.yaml" <<YAML
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${REGION}
  version: "${K8S_VERSION}"
iam:
  withOIDC: true
managedNodeGroups:
  - name: ng-1
    instanceType: ${NODE_INSTANCE_TYPE}
    desiredCapacity: ${DESIRED_CAPACITY}
    minSize: 2
    maxSize: 4
    amiFamily: AmazonLinux2023
YAML


sed -i '' -e "s/introspect-cluster/${CLUSTER_NAME}/g" \
          -e "s/us-east-1/${REGION}/g" \
          -e "s/\"1.33\"/\"${K8S_VERSION}\"/g" \
          -e "s/t3.medium/${NODE_INSTANCE_TYPE}/g" \
          -e "s/desiredCapacity: 2/desiredCapacity: ${DESIRED_CAPACITY}/g" "$EKS_DIR/eksctl-cluster.yaml"

############################################
# CREATE EKS CLUSTER
############################################
echo ">>> Creating EKS cluster ${CLUSTER_NAME} in ${REGION} (this can take 10-15 minutes)..."
eksctl create cluster -f "$EKS_DIR/eksctl-cluster.yaml" || true

echo ">>> Checking nodes"
kubectl get nodes -o wide

############################################
# INSTALL EBS CSI ADD-ON (for Dapr Scheduler PVCs)
############################################
echo ">>> Installing EBS CSI add-on"
eksctl create addon --name aws-ebs-csi-driver --cluster "${CLUSTER_NAME}" --region "${REGION}" --force || true
aws eks wait addon-active --cluster-name "${CLUSTER_NAME}" --region "${REGION}" --addon-name aws-ebs-csi-driver

############################################
# INSTALL DAPR (Helm pinned v1.16.4)
############################################
echo ">>> Installing Dapr control plane via Helm"
helm repo add dapr https://dapr.github.io/helm-charts/ || true
helm repo update
helm upgrade --install dapr dapr/dapr \
  --namespace dapr-system --create-namespace \
  --wait --version 1.16.4

kubectl get pods -n dapr-system -o wide

############################################
# CREATE IRSA POLICY FOR SNS/SQS (no static keys)
############################################
echo ">>> Creating IAM policy for Dapr SNS/SQS component (IRSA)"
cat > "$EKS_DIR/dapr-snssqs-policy.json" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SNS",
      "Effect": "Allow",
      "Action": [
        "sns:CreateTopic",
        "sns:Subscribe",
        "sns:ListTopics",
        "sns:ListSubscriptionsByTopic",
        "sns:Publish"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SQS",
      "Effect": "Allow",
      "Action": [
        "sqs:CreateQueue",
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:SetQueueAttributes",
        "sqs:ListQueues",
        "sqs:SendMessage"
      ],
      "Resource": "*"
    }
  ]
}
JSON

POLICY_ARN="$(aws iam list-policies --query "Policies[?PolicyName=='dapr-snssqs-policy'].Arn | [0]" --output text)"
if [[ "$POLICY_ARN" == "None" || -z "$POLICY_ARN" ]]; then
  POLICY_ARN="$(aws iam create-policy --policy-name dapr-snssqs-policy \
    --policy-document file://$EKS_DIR/dapr-snssqs-policy.json \
    --query 'Policy.Arn' --output text)"
fi
echo "Policy ARN: ${POLICY_ARN}"


