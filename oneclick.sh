
#!/usr/bin/env bash
cd "$(dirname "$0")"
set -euo pipefail

# ========= CONFIG =========
ACCOUNT_ID="${ACCOUNT_ID:-}"
REGION="${REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-dapr-eks}"
NAMESPACE="${NAMESPACE:-dapr-apps}"
AWS_PROFILE="${AWS_PROFILE:-Deepak}"

# Source dirs (adjust if your repo differs)
PRODUCT_DIR="${PRODUCT_DIR:-src/productservice}"
ORDER_DIR="${ORDER_DIR:-src/orderservice}"

# ECR repo names (flat names are safest for ECR)
PRODUCT_REPO="${PRODUCT_REPO:-productservice}"
ORDER_REPO="${ORDER_REPO:-orderservice}"

# Tag (timestamp by default)
IMAGE_TAG="${IMAGE_TAG:-$(date -u +%Y%m%d%H%M%S)}"

echo "==> Using ACCOUNT_ID=$ACCOUNT_ID REGION=$REGION CLUSTER_NAME=$CLUSTER_NAME NAMESPACE=$NAMESPACE"
if [[ -z "$ACCOUNT_ID" ]]; then
  echo "ERROR: ACCOUNT_ID is required. Set it as environment variable or pass as argument."
  echo "Usage: ACCOUNT_ID=123456789012 ./oneclick.sh"
  exit 1
fi
aws configure set region "$REGION"


# ========= EKS cluster creation (idempotent) =========
echo "==> Checking if EKS cluster '$CLUSTER_NAME' exists in $REGION"
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1; then
  echo "   Cluster '$CLUSTER_NAME' already exists. Skipping creation."
else
  echo "==> Creating EKS cluster '$CLUSTER_NAME' in $REGION"
  eksctl create cluster \
    --name "$CLUSTER_NAME" \
    --region "$REGION" \
    --version 1.32 \
    --nodegroup-name ng-1 \
    --node-type t3.medium \
    --nodes 2 \
    --nodes-min 1 \
    --nodes-max 3 \
    --managed

  echo "==> Waiting for EKS control plane to become active"
  aws eks wait cluster-active --name "$CLUSTER_NAME" --region "$REGION" --profile "$AWS_PROFILE"
fi

echo "==> Updating kubeconfig"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" --profile "$AWS_PROFILE"

# Try kubectl a few times while nodes register
echo "==> Checking cluster nodes"
for i in {1..10}; do
  if kubectl get nodes >/dev/null 2>&1; then
    kubectl get nodes -o wide
    break
  fi
  echo "   Nodes not ready yet, retrying ($i/10)..."
  sleep 15
done


# ========= EBS CSI Driver (required for PVCs) =========
echo "==> Installing EBS CSI driver addon"
# Create IAM role for EBS CSI driver
OIDC_ISSUER=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --profile "$AWS_PROFILE" --query "cluster.identity.oidc.issuer" --output text | sed 's|https://||')
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_ISSUER}"

# Check if OIDC provider exists, create if not
if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" --profile "$AWS_PROFILE" >/dev/null 2>&1; then
  echo "   Creating OIDC provider: $OIDC_ARN"
  aws iam create-open-id-connect-provider \
    --url "https://${OIDC_ISSUER}" \
    --thumbprint-list 9e99a48a9960b14926bb7f3b02e22da2b0ab7280 \
    --client-id-list sts.amazonaws.com \
    --profile "$AWS_PROFILE" >/dev/null
fi

# Create IAM role for EBS CSI driver
cat > ebs-csi-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_ISSUER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_ISSUER}:sub": "system:serviceaccount:kube-system:ebs-csi-controller-sa",
          "${OIDC_ISSUER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name AmazonEKS_EBS_CSI_DriverRole \
  --assume-role-policy-document file://ebs-csi-trust-policy.json \
  --profile "$AWS_PROFILE" 2>/dev/null || true

aws iam attach-role-policy \
  --role-name AmazonEKS_EBS_CSI_DriverRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --profile "$AWS_PROFILE" 2>/dev/null || true


kubectl create serviceaccount ebs-csi-controller-sa -n kube-system --dry-run=client -o yaml \
  | kubectl annotate --local -f - \
      eks.amazonaws.com/role-arn="arn:aws:iam::${ACCOUNT_ID}:role/AmazonEKS_EBS_CSI_DriverRole" -o yaml \
  | kubectl apply -f - 2>/dev/null || true


# Install EBS CSI addon
aws eks create-addon \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name aws-ebs-csi-driver \
  --region "$REGION" \
  --profile "$AWS_PROFILE" \
  --service-account-role-arn arn:aws:iam::${ACCOUNT_ID}:role/AmazonEKS_EBS_CSI_DriverRole \
  --resolve-conflicts OVERWRITE >/dev/null 2>&1 || true

echo "==> Waiting for EBS CSI driver to be ready"
for i in {1..10}; do
  STATUS=$(aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name aws-ebs-csi-driver --region "$REGION" --profile "$AWS_PROFILE" --query 'addon.status' --output text 2>/dev/null || echo "CREATING")
  if [[ "$STATUS" == "ACTIVE" ]]; then
    echo "   EBS CSI driver is active"
    break
  fi
  echo "   EBS CSI driver status: $STATUS, waiting... ($i/10)"
  sleep 30
done

# ========= Namespace =========
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE"
# ========= Dapr control plane =========
if ! helm repo list | awk '{print $1}' | grep -qx dapr; then
  helm repo add dapr https://dapr.github.io/helm-charts
else
  helm repo add dapr https://dapr.github.io/helm-charts --force-update
fi
helm repo update
DEMO_MODE="${DEMO_MODE:-false}"
# Ensure a default StorageClass exists (try to use gp2, otherwise apply bundled ebs-gp3)
echo "==> Checking for default StorageClass"
DEFAULT_SC=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || true)
if [ -z "${DEFAULT_SC}" ]; then
  echo "No default StorageClass found. Attempting to set gp2 as default or create ebs-gp3."
  if kubectl get storageclass gp2 >/dev/null 2>&1; then
    echo "Setting gp2 as the default StorageClass"
    kubectl patch storageclass gp2 -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' || true
  else
    echo "Applying eks/ebs-gp3-sc.yaml"
    kubectl apply -f eks/ebs-gp3-sc.yaml || true
  fi
else
  echo "Found default StorageClass: ${DEFAULT_SC}"
fi

DAPR_CHART_VERSION="1.16.5"
HELM_EXTRA_ARGS=""
DEMO_MODE="${DEMO_MODE:-false}"
if [ "${DEMO_MODE}" = "true" ]; then
  echo "DEMO_MODE=true: disabling scheduler persistence (recommended for lab environments)"
  HELM_EXTRA_ARGS="--set scheduler.persistence.enabled=false"
fi

echo "==> Installing/Upgrading Dapr control plane (chart version: ${DAPR_CHART_VERSION})"
if ! helm upgrade --install dapr dapr/dapr \
  --namespace dapr-system \
  --create-namespace \
  --version "${DAPR_CHART_VERSION}" \
  ${HELM_EXTRA_ARGS} \
  --wait --atomic --timeout 15m0s; then
  echo "Helm install/upgrade for Dapr failed — gathering diagnostics"
  kubectl -n dapr-system get pods -o wide || true
  kubectl -n dapr-system describe pod -l app.kubernetes.io/name=dapr || true
  kubectl -n dapr-system get pvc || true
  exit 1
fi

# ========= IRSA ServiceAccounts =========
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-serviceaccount.yaml


# ========= IRSA REBIND (ensure trust matches current OIDC issuer & SA is annotated) =========
echo "==> (IRSA) Rebinding role trust to current EKS OIDC issuer & annotating SA"

ACCOUNT_ID="${ACCOUNT_ID}"
AWS_PROFILE="${AWS_PROFILE:-Deepak}"
REGION="${REGION:-us-east-1}"
ROLE_NAME="DaprSNS_SQS_PubSubRole"
SA_NS="${NAMESPACE:-dapr-apps}"
SA_NAME="dapr-pubsub-sa"



# Ensure namespace & ServiceAccount exist (idempotent)
kubectl get ns "${SA_NS}" >/dev/null 2>&1 || kubectl create ns "${SA_NS}"
kubectl get sa "${SA_NAME}" -n "${SA_NS}" >/dev/null 2>&1 || kubectl create sa "${SA_NAME}" -n "${SA_NS}"


# 1) Resolve the current cluster OIDC issuer
OIDC_ISSUER_URL=$(aws eks describe-cluster \
  --name "${CLUSTER_NAME}" \
  --region "${REGION}" \
  --profile "${AWS_PROFILE}" \
  --query "cluster.identity.oidc.issuer" \
  --output text)

OIDC_ISSUER=${OIDC_ISSUER_URL#https://}

# 2) Ensure the IAM OIDC provider exists for this issuer (create if missing)
OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_ISSUER}"
aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn "${OIDC_PROVIDER_ARN}" \
  --profile "${AWS_PROFILE}" >/dev/null 2>&1 || aws iam create-open-id-connect-provider \
  --url "${OIDC_ISSUER_URL}" \
  --thumbprint-list 9e99a48a9960b14926bb7f3b02e22da2b0ab7280 \
  --client-id-list sts.amazonaws.com \
  --profile "${AWS_PROFILE}"


# 3) Desired trust policy (scoped to SA:dapr-pubsub-sa in ns:dapr-apps)
cat > irsa-updated-trust.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_ISSUER}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_ISSUER}:aud": "sts.amazonaws.com",
        "${OIDC_ISSUER}:sub": "system:serviceaccount:${SA_NS}:${SA_NAME}"
      }
    }
  }]
}
JSON

# 4) Create the IRSA role if missing (idempotent)
aws iam get-role --role-name "${ROLE_NAME}" --profile "${AWS_PROFILE}" >/dev/null 2>&1 || \
aws iam create-role \
  --role-name "${ROLE_NAME}" \
  --assume-role-policy-document file://irsa-updated-trust.json \
  --profile "${AWS_PROFILE}"

# 5) Attach SNS/SQS policies (idempotent, suitable for a lab)
aws iam attach-role-policy --role-name "${ROLE_NAME}" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSNSFullAccess \
  --profile "${AWS_PROFILE}" >/dev/null 2>&1 || true

aws iam attach-role-policy --role-name "${ROLE_NAME}" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSQSFullAccess \
  --profile "${AWS_PROFILE}" >/dev/null 2>&1 || true

# 6) Update trust (idempotent)
aws iam update-assume-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-document file://irsa-updated-trust.json \
  --profile "${AWS_PROFILE}"

# 7) Annotate the ServiceAccount with the IRSA role ARN (idempotent)
ROLE_ARN=$(aws iam get-role --role-name "${ROLE_NAME}" \
  --query 'Role.Arn' --output text --profile "${AWS_PROFILE}")

kubectl annotate sa "${SA_NAME}" -n "${SA_NS}" \
  eks.amazonaws.com/role-arn="${ROLE_ARN}" --overwrite

echo "   IRSA role ARN: $ROLE_ARN"

# ========= Enable OIDC provider for IRSA =========
echo "==> OIDC provider already configured in EBS CSI section"


# ========= IRSA v2 policy for SNS/SQS =========
mkdir -p eks
cat > eks/dapr-snssqs-policy-v2.json <<'JSON'
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
        "sns:Publish",
        "sns:TagResource",
        "sns:GetTopicAttributes",
        "sns:SetTopicAttributes"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SQS",
      "Effect": "Allow",
      "Action": [
        "sqs:CreateQueue",
        "sqs:GetQueueUrl",
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:SetQueueAttributes",
        "sqs:ListQueues",
        "sqs:SendMessage",
        "sqs:TagQueue"
      ],
      "Resource": "*"
    }
  ]
}
JSON

POLICY_NAME="dapr-snssqs-policy-v2"
echo "==> Ensuring IRSA v2 policy exists"
NEW_POLICY_ARN=$(aws iam list-policies \
  --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn | [0]" \
  --output text --profile "$AWS_PROFILE" 2>/dev/null)
if [[ -z "${NEW_POLICY_ARN}" || "${NEW_POLICY_ARN}" == "None" ]]; then
  NEW_POLICY_ARN=$(aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document "file://eks/dapr-snssqs-policy-v2.json" \
    --query 'Policy.Arn' --output text --profile "$AWS_PROFILE")
fi
echo "   IRSA v2 policy ARN: $NEW_POLICY_ARN"


# ========= Dapr AWS SNS/SQS component =========
kubectl apply -f dapr/snssqs-pubsub.yaml


# ========= Build & Push Images (automatic) =========

# detect node architecture to choose build platform (fallback amd64)
PLATFORM="linux/amd64"
NODE_ARCH="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || true)"
if [[ "$NODE_ARCH" == "arm64" || "$NODE_ARCH" == "aarch64" ]]; then PLATFORM="linux/arm64"; fi
echo "==> Building images for platform: $PLATFORM"

ECR="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
PRODUCT_IMAGE="${ECR}/${PRODUCT_REPO}:${IMAGE_TAG}"
ORDER_IMAGE="${ECR}/${ORDER_REPO}:${IMAGE_TAG}"

echo "==> ECR login"
aws ecr get-login-password --region "$REGION" --profile "$AWS_PROFILE" | docker login --username AWS --password-stdin "$ECR"

echo "==> Ensure ECR repos exist"
aws ecr describe-repositories --repository-names "$PRODUCT_REPO" --profile "$AWS_PROFILE" >/dev/null 2>&1 || \
  aws ecr create-repository --repository-name "$PRODUCT_REPO" \
    --image-scanning-configuration scanOnPush=true --profile "$AWS_PROFILE" >/dev/null
aws ecr describe-repositories --repository-names "$ORDER_REPO" --profile "$AWS_PROFILE" >/dev/null 2>&1 || \
  aws ecr create-repository --repository-name "$ORDER_REPO" \
    --image-scanning-configuration scanOnPush=true --profile "$AWS_PROFILE" >/dev/null

echo "==> Building & pushing ProductService -> $PRODUCT_IMAGE"
test -f "${PRODUCT_DIR}/Dockerfile" || { echo "Missing ${PRODUCT_DIR}/Dockerfile"; exit 1; }

# ProductService build & push
docker buildx build --platform "$PLATFORM" \
  -t "$PRODUCT_IMAGE" \
  -f "${PRODUCT_DIR}/Dockerfile" \
  "${PRODUCT_DIR}" \
  --push


# --- Silence platform mismatch warning (optional but recommended) ---
export DOCKER_DEFAULT_PLATFORM=linux/amd64
docker buildx create --name amd64builder --use >/dev/null 2>&1 || true
docker buildx inspect --bootstrap >/dev/null 2>&1 || true


echo "==> Building & pushing OrderService   -> $ORDER_IMAGE"
test -f "${ORDER_DIR}/Dockerfile" || { echo "Missing ${ORDER_DIR}/Dockerfile"; exit 1; }

docker buildx build --platform "$PLATFORM" \
  -t "$ORDER_IMAGE" \
  -f "${ORDER_DIR}/Dockerfile" \
  "${ORDER_DIR}" \
  --push


# ========= App Deployments =========
kubectl apply -f k8s/10-productservice.yaml
kubectl apply -f k8s/11-orderservice.yaml

# Pin deployments to the freshly pushed timestamp tags
kubectl set image deployment/productservice \
  productservice=${ECR}/${PRODUCT_REPO}:${IMAGE_TAG} -n "$NAMESPACE"
kubectl set image deployment/orderservice \
  orderservice=${ECR}/${ORDER_REPO}:${IMAGE_TAG} -n "$NAMESPACE"

# Restart once so pods pick up refreshed IRSA token (issuer/trust may have just changed)
kubectl rollout restart deployment/productservice -n "$NAMESPACE" || true
kubectl rollout restart deployment/orderservice  -n "$NAMESPACE" || true

echo "==> Waiting for Product & Order deployments (after IRSA refresh)"
kubectl rollout status deployment/productservice -n "$NAMESPACE"
kubectl rollout status deployment/orderservice  -n "$NAMESPACE"

# ========= Subscription =========
kubectl apply -f dapr/subscription-orders.yaml

# Restart OrderService so daprd reloads the subscription
kubectl rollout restart deployment/orderservice -n "$NAMESPACE" || true
kubectl rollout status  deployment/orderservice -n "$NAMESPACE"


echo "==> Waiting for Product & Order deployments"
kubectl get pods -n "$NAMESPACE" -o wide || true

# ========= Test the deployment =========
echo "==> Testing pub/sub functionality"
kubectl run test-curl -n "$NAMESPACE" --restart=Never \
  --image=curlimages/curl:8.10.1 \
  --rm -i --command -- \
  curl -X POST "http://productservice:8080/publish" \
    -H "Content-Type: application/json" \
    -d '{"orderId": 123, "item":"test-item", "price": 99.99}'

echo -e "\n==> OrderService logs:"
kubectl logs deploy/orderservice -n "$NAMESPACE" --tail=10 || true

echo -e "\n==> Deployment complete! Check pod status:"
kubectl get pods -n "$NAMESPACE" -o wide

