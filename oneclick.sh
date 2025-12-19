
#!/usr/bin/env bash
set -euo pipefail

# ========= CONFIG =========
ACCOUNT_ID="${ACCOUNT_ID:-946248011760}"
REGION="${REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-dapr-eks}"
NAMESPACE="${NAMESPACE:-default}"

# Source dirs (adjust if your repo differs)
PRODUCT_DIR="${PRODUCT_DIR:-src/productservice}"
ORDER_DIR="${ORDER_DIR:-src/orderservice}"

# ECR repo names (flat names are safest for ECR)
PRODUCT_REPO="${PRODUCT_REPO:-productservice}"
ORDER_REPO="${ORDER_REPO:-orderservice}"

# Tag (timestamp by default)
IMAGE_TAG="${IMAGE_TAG:-$(date -u +%Y%m%d%H%M%S)}"

echo "==> Using ACCOUNT_ID=$ACCOUNT_ID REGION=$REGION CLUSTER_NAME=$CLUSTER_NAME NAMESPACE=$NAMESPACE"
aws configure set region "$REGION"

# ========= Namespace =========
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE"

# ========= Dapr control plane =========
helm repo add dapr https://dapr.github.io/helm-charts >/dev/null
helm repo update >/dev/null
echo "==> Installing/Upgrading Dapr control plane"
helm upgrade --install dapr dapr/dapr \
  --namespace dapr-system \
  --create-namespace \
  --wait

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
  --output text | head -n1)
if [[ -z "${NEW_POLICY_ARN}" || "${NEW_POLICY_ARN}" == "None" ]]; then
  NEW_POLICY_ARN=$(aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document "file://eks/dapr-snssqs-policy-v2.json" \
    --query 'Policy.Arn' --output text)
fi
echo "   IRSA v2 policy ARN: $NEW_POLICY_ARN"

# ========= IRSA ServiceAccounts (adjust role-arn if needed) =========
cat > sa-irsa.yaml <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: product-dapr-irsa
  namespace: ${NAMESPACE}
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::${ACCOUNT_ID}:role/product-dapr-irsa-role
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: order-dapr-irsa
  namespace: ${NAMESPACE}
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::${ACCOUNT_ID}:role/order-dapr-irsa-role
YAML
kubectl apply -f sa-irsa.yaml

# Attach policy to both IRSA roles (if present)
echo "==> Attaching policy to Product & Order roles (if present)"
for ROLE_ARN in \
  "$(kubectl get sa product-dapr-irsa -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' || true)" \
  "$(kubectl get sa order-dapr-irsa   -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' || true)"; do
  if [[ -n "$ROLE_ARN" && "$ROLE_ARN" != "None" ]]; then
    ROLE_NAME="${ROLE_ARN##*/}"
    aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$NEW_POLICY_ARN" || true
    echo "   Attached $POLICY_NAME to $ROLE_NAME"
  fi
done

# ========= SNS Topic guard (avoid tag mismatch) =========
echo "==> Deleting existing SNS topic 'orders' (if present)"
ORDERS_TOPIC_ARN=$(aws sns list-topics --region "$REGION" \
  --query "Topics[?ends_with(TopicArn, ':orders')].TopicArn | [0]" \
  --output text | head -n1)
if [[ -n "$ORDERS_TOPIC_ARN" && "$ORDERS_TOPIC_ARN" != "None" ]]; then
  aws sns delete-topic --topic-arn "$ORDERS_TOPIC_ARN" --region "$REGION" || true
  echo "   Deleted $ORDERS_TOPIC_ARN"
fi

# ========= Dapr AWS SNS/SQS component =========
cat > dapr-snssqs-component.yaml <<YAML
apiVersion: dapr.io/v1alpha1
kind: Component
metadata:
  name: snssqs-pubsub
  namespace: ${NAMESPACE}
spec:
  type: pubsub.aws.snssqs
  version: v1
  metadata:
    - name: region
      value: "${REGION}"
YAML
kubectl apply -f dapr-snssqs-component.yaml

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
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR"

echo "==> Ensure ECR repos exist"
aws ecr describe-repositories --repository-names "$PRODUCT_REPO" >/dev/null 2>&1 || \
  aws ecr create-repository --repository-name "$PRODUCT_REPO" \
    --image-scanning-configuration scanOnPush=true >/dev/null
aws ecr describe-repositories --repository-names "$ORDER_REPO" >/dev/null 2>&1 || \
  aws ecr create-repository --repository-name "$ORDER_REPO" \
    --image-scanning-configuration scanOnPush=true >/dev/null

echo "==> Building & pushing ProductService -> $PRODUCT_IMAGE"
test -f "${PRODUCT_DIR}/Dockerfile" || { echo "Missing ${PRODUCT_DIR}/Dockerfile"; exit 1; }
docker buildx build --platform "$PLATFORM" -t "$PRODUCT_IMAGE" -f "${PRODUCT_DIR}/Dockerfile" "${PRODUCT_DIR}" --push

echo "==> Building & pushing OrderService   -> $ORDER_IMAGE"
test -f "${ORDER_DIR}/Dockerfile" || { echo "Missing ${ORDER_DIR}/Dockerfile"; exit 1; }
docker buildx build --platform "$PLATFORM" -t "$ORDER_IMAGE" -f "${ORDER_DIR}/Dockerfile" "${ORDER_DIR}" --push

# ========= App Deployments (wired with computed images) =========
cat > k8s-apps.yaml <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: productservice
  namespace: ${NAMESPACE}
  labels:
    app: productservice
spec:
  replicas: 1
  selector:
    matchLabels:
      app: productservice
  template:
    metadata:
      labels:
        app: productservice
      annotations:
        dapr.io/enabled: "true"
        dapr.io/app-id: "productservice"
        dapr.io/app-port: "8080"
        dapr.io/listen-addresses: "0.0.0.0"
        dapr.io/sidecar-listen-addresses: "0.0.0.0"
        dapr.io/log-level: "info"
    spec:
      serviceAccountName: product-dapr-irsa
      containers:
      - name: productservice
        image: ${PRODUCT_IMAGE}
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orderservice
  namespace: ${NAMESPACE}
  labels:
    app: orderservice
spec:
  replicas: 1
  selector:
    matchLabels:
      app: orderservice
  template:
    metadata:
      labels:
        app: orderservice
      annotations:
        dapr.io/enabled: "true"
        dapr.io/app-id: "orderservice"
        dapr.io/app-port: "8090"
        dapr.io/listen-addresses: "0.0.0.0"
        dapr.io/sidecar-listen-addresses: "0.0.0.0"
        dapr.io/log-level: "info"
    spec:
      serviceAccountName: order-dapr-irsa
      containers:
      - name: orderservice
        image: ${ORDER_IMAGE}
        imagePullPolicy: Always
        env:
        - name: PORT
          value: "8090"
        ports:
        - containerPort: 8090
YAML
kubectl apply -f k8s-apps.yaml

# ========= Subscription (route matches /orders handler) =========
cat > dapr-subscription.yaml <<YAML
apiVersion: dapr.io/v2alpha1
kind: Subscription
metadata:
  name: orders-sub-products
  namespace: ${NAMESPACE}
scopes:
- orderservice
spec:
  pubsubname: snssqs-pubsub
  topic: orders
  routes:
    default: /orders
YAML
kubectl apply -f dapr-subscription.yaml

echo "==> Waiting for Product & Order deployments"
kubectl wait --for=condition=Available deployment/productservice -n "$NAMESPACE" --timeout=300s || true
kubectl wait --for=condition=Available deployment/orderservice   -n "$NAMESPACE" --timeout=300s || true
kubectl get pods -n "$NAMESPACE" -o wide || true

# ========= Publish test (call sidecar port 3500) =========
echo "==> Publishing test message via productservice Dapr sidecar"
kubectl delete pod curl-test wget-test -n "$NAMESPACE" --ignore-not-found || true

kubectl run curl-test -n "$NAMESPACE" --restart=Never \
  --image=curlimages/curl:8.10.1 \
  --command -- sh -lc \
  'curl -v -i -s -X POST "http://productservice-dapr:3500/v1.0/publish/snssqs-pubsub/orders" \
     -H "Content-Type: application/json" \
     -d "{\"id\":\"bootstrap\",\"name\":\"OneClick\",\"price\":1.00,\"updatedAt\":\"$(date -u +%FT%TZ)\"}" && sleep 1' || true

kubectl logs curl-test -n "$NAMESPACE" || true
kubectl delete pod curl-test -n "$NAMESPACE" --wait=false 2>/dev/null || true

echo "==> OrderService logs (app + sidecar)"
kubectl logs deploy/orderservice -n "$NAMESPACE" --tail=100 || true
kubectl logs deploy/orderservice -n "$NAMESPACE" -kubectl logs deploy/orderservice -n "$NAMESPACE" -c daprd --tail=100 || true

