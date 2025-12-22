
#!/usr/bin/env bash
set -euo pipefail

# =========================
# CONFIGURE / OVERRIDES
# =========================
CLUSTER_NAME="${CLUSTER_NAME:-dapr-eks}"
REGION="${REGION:-us-east-1}"
K8S_NAMESPACE="${K8S_NAMESPACE:-dapr-apps}"
AWS_PROFILE="${AWS_PROFILE:-Deepak}"
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
for cmd in aws kubectl; do
  command -v "$cmd" >/dev/null || die "Missing dependency: $cmd"
done

ACCOUNT_ID="$(aws sts get-caller-identity --profile $AWS_PROFILE --query Account --output text)"

log "Planned deletions in account ${ACCOUNT_ID}, region ${REGION}:"
cat <<EOF
- Kubernetes app resources in namespace '${K8S_NAMESPACE}'
- Dapr control plane (Helm release 'dapr') + namespace 'dapr-system'
- EKS cluster: ${CLUSTER_NAME} (including nodegroups)
- ECR repositories: productservice, orderservice (with images)
- IAM role: AmazonEKS_EBS_CSI_DriverRole
- OIDC provider for the cluster
EOF

if [[ "$FORCE" != "1" ]]; then
  read -r -p $'\nType "delete" to proceed (or Ctrl+C to abort): ' CONFIRM
  [[ "$CONFIRM" == "delete" ]] || die "User aborted; nothing deleted."
fi

# =========================
# 1) KUBERNETES APP RESOURCES
# =========================
log "Deleting app namespaces and resources…"
kubectl delete namespace "$K8S_NAMESPACE" --force --grace-period=0 2>/dev/null || true
kubectl delete namespace dapr-system --force --grace-period=0 2>/dev/null || true

# =========================
# 2) ECR REPOSITORIES
# =========================
log "Deleting ECR repositories (force: deletes images)…"
for REPO in productservice orderservice; do
  aws ecr delete-repository --repository-name "$REPO" \
    --region "${REGION}" --profile "$AWS_PROFILE" --force >/dev/null 2>&1 || warn "ECR repo '$REPO' not found."
done

# =========================
# 3) EKS CLUSTER DELETION
# =========================
log "Deleting EKS nodegroups first…"
NODEGROUPS=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$REGION" --profile "$AWS_PROFILE" --query 'nodegroups' --output text 2>/dev/null || echo "")
for NG in $NODEGROUPS; do
  if [[ -n "$NG" && "$NG" != "None" ]]; then
    log "Deleting nodegroup: $NG"
    aws eks delete-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NG" --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true
    aws eks wait nodegroup-deleted --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NG" --region "$REGION" --profile "$AWS_PROFILE" 2>/dev/null || true
  fi
done

log "Deleting EKS cluster '${CLUSTER_NAME}'…"
aws eks delete-cluster --name "${CLUSTER_NAME}" --region "${REGION}" --profile "$AWS_PROFILE" >/dev/null 2>&1 || warn "Cluster not found or already deleted"

# =========================
# 4) IAM RESOURCES CLEANUP
# =========================
log "Cleaning up IAM resources…"
# Detach and delete EBS CSI IAM role
aws iam detach-role-policy --role-name AmazonEKS_EBS_CSI_DriverRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy --profile "$AWS_PROFILE" 2>/dev/null || true
aws iam delete-role --role-name AmazonEKS_EBS_CSI_DriverRole --profile "$AWS_PROFILE" 2>/dev/null || true

# Delete OIDC provider
OIDC_PROVIDERS=$(aws iam list-open-id-connect-providers --profile "$AWS_PROFILE" --query 'OpenIDConnectProviderList[].Arn' --output text 2>/dev/null || echo "")
for PROVIDER in $OIDC_PROVIDERS; do
  if [[ "$PROVIDER" == *"eks"* ]]; then
    aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER" --profile "$AWS_PROFILE" 2>/dev/null || true
    log "Deleted OIDC provider: $PROVIDER"
  fi
done

# Optional: clean local kube context (best-effort)
CTX_NAME="$(kubectl config get-contexts -o name | grep -E "${CLUSTER_NAME}" || true)"
if [[ -n "$CTX_NAME" ]]; then
  log "Deleting local kubectl context '${CTX_NAME}'…"
  kubectl config delete-context "$CTX_NAME" || true
fi

log "Cleanup complete."
echo "Account: ${ACCOUNT_ID}  Region: ${REGION}"

