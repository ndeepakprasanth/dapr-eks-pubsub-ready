
#!/usr/bin/env bash
set -euo pipefail

# =========================
# CONFIGURE / OVERRIDES
# =========================
CLUSTER_NAME="${CLUSTER_NAME:-introspect-cluster}"
REGION="${REGION:-us-east-1}"
K8S_NAMESPACE="${K8S_NAMESPACE:-default}"
EKS_DIR="${EKS_DIR:-eks}"
ECR_DIR="${ECR_DIR:-ecr}"
DAPR_DIR="${DAPR_DIR:-dapr}"
K8S_DIR="${K8S_DIR:-k8s}"
FORCE="${FORCE:-0}"   # set to 1 or pass --yes to skip confirmation

# =========================
# HELPERS
# =========================
log()  { printf "\n>>> %s\n" "$*"; }
warn() { printf "\n[!] %s\n" "$*"; }
die()  { printf "\n[✖] %s\n" "$*"; exit 1; }

# Parse flags
while [[ "${1:-}" != "" ]]; do
  case "$1" in
    --yes|-y) FORCE=1 ;;
    --cluster) shift; CLUSTER_NAME="${1:-$CLUSTER_NAME}" ;;
    --region)  shift; REGION="${1:-$REGION}" ;;
    *) warn "Unknown argument: $1" ;;
  esac
  shift || true
done

# Pre-checks
for cmd in aws eksctl kubectl helm docker; do
  command -v "$cmd" >/dev/null || die "Missing dependency: $cmd"
done

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

log "Planned deletions in account ${ACCOUNT_ID}, region ${REGION}:"
cat <<EOF
- Kubernetes app resources in namespace '${K8S_NAMESPACE}':
  * Deployments/Services: productservice, orderservice
  * Dapr Component: snssqs-pubsub
  * Dapr Subscription: orders-sub-products
  * ServiceAccount (IRSA): order-dapr-irsa
- Dapr control plane (Helm release 'dapr') + namespace 'dapr-system'
- EKS add-on: aws-ebs-csi-driver
- ECR repositories: productservice, orderservice (with images)
- IAM policy: 'dapr-snssqs-policy' (detaching if needed)
- EKS cluster: ${CLUSTER_NAME}
EOF

if [[ "$FORCE" != "1" ]]; then
  read -r -p $'\nType "delete" to proceed (or Ctrl+C to abort): ' CONFIRM
  [[ "$CONFIRM" == "delete" ]] || die "User aborted; nothing deleted."
fi

# =========================
# 1) KUBERNETES APP RESOURCES
# =========================
log "Deleting app Deployments/Services (productservice, orderservice)…"
kubectl delete -f "$K8S_DIR/productservice.yaml" --ignore-not-found || true
kubectl delete -f "$K8S_DIR/orderservice.yaml" --ignore-not-found || true

log "Deleting Dapr Subscription and Component…"
kubectl delete -f "$DAPR_DIR/subscription-orders.yaml" --ignore-not-found || true
kubectl delete -f "$DAPR_DIR/pubsub-snssqs.yaml" --ignore-not-found || true

log "Deleting IRSA ServiceAccount (K8s) if present…"
kubectl delete sa order-dapr-irsa -n "$K8S_NAMESPACE" --ignore-not-found || true

# =========================
# 2) DAPR CONTROL PLANE
# =========================
log "Uninstalling Dapr control plane (Helm)…"
helm uninstall dapr -n dapr-system || true
kubectl delete ns dapr-system --ignore-not-found || true

# =========================
# 3) EKS ADD-ON (EBS CSI)
# =========================
log "Deleting EKS add-on 'aws-ebs-csi-driver'…"
aws eks delete-addon --cluster-name "${CLUSTER_NAME}" \
  --addon-name aws-ebs-csi-driver --region "${REGION}" \
  >/dev/null 2>&1 || true

# =========================
# 4) IRSA ROLE (IAM) AND POLICY
# =========================
log "Deleting IRSA (IAM role + K8s SA) via eksctl (safe teardown)…"
eksctl delete iamserviceaccount \
  --name order-dapr-irsa \
  --namespace "${K8S_NAMESPACE}" \
  --cluster "${CLUSTER_NAME}" \
  --region "${REGION}" || true

# Detach and delete IAM policy created for SNS/SQS
POLICY_ARN="$(aws iam list-policies \
  --query "Policies[?PolicyName=='dapr-snssqs-policy'].Arn | [0]" --output text)"
if [[ -n "$POLICY_ARN" && "$POLICY_ARN" != "None" ]]; then
  log "Detaching and deleting IAM policy 'dapr-snssqs-policy' (${POLICY_ARN})…"
  ROLES=$(aws iam list-entities-for-policy --policy-arn "$POLICY_ARN" \
    --query 'PolicyRoles[].RoleName' --output text || true)
  for ROLE in $ROLES; do
    aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$POLICY_ARN" || true
  done
  aws iam delete-policy --policy-arn "$POLICY_ARN" || true
else
  warn "IAM policy 'dapr-snssqs-policy' not found or already deleted."
fi

# =========================
# 5) ECR REPOSITORIES
# =========================
log "Deleting ECR repositories (force: deletes images)…"
for REPO in productservice orderservice; do
  aws ecr delete-repository --repository-name "$REPO" \
    --region "${REGION}" --force >/dev/null 2>&1 || warn "ECR repo '$REPO' not found."
done

# =========================
# 6) EKS CLUSTER
# =========================
log "Deleting EKS cluster '${CLUSTER_NAME}' (this can take several minutes)…"
eksctl delete cluster --name "${CLUSTER_NAME}" --region "${REGION}" --wait || true

# Optional: clean local kube context (best-effort)
CTX_NAME="$(kubectl config get-contexts -o name | grep -E "${CLUSTER_NAME}" || true)"
if [[ -n "$CTX_NAME" ]]; then
  log "Deleting local kubectl context '${CTX_NAME}'…"
  kubectl config delete-context "$CTX_NAME" || true
fi

log "Cleanup complete."
echo "Account: ${ACCOUNT_ID}  Region: ${REGION}"

