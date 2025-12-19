
#!/usr/bin/env bash
set -euo pipefail

# ===========================
# Dapr + EKS end-to-end setup
# ===========================
# This orchestrates:
#   1) EKS w/ OIDC & IRSA  -> ./eks/create-cluster.sh
#   2) Build & push images -> ./scripts/build_push.sh
#   3) Install Dapr & apps -> ./scripts/deploy.sh
#
# Usage:
#   ./orchestrate.sh --account <AWS_ACCOUNT_ID> [--region us-east-1] [--prefix dapr-eks-pubsub] [--skip-cluster] [--skip-build] [--skip-deploy] [--dry-run]
#
# Examples:
#   ./orchestrate.sh --account 123456789012
#   ./orchestrate.sh --account 123456789012 --region eu-west-1 --prefix myteam/dapr
#
# Env overrides (optional):
#   AWS_ACCOUNT_ID, AWS_REGION, ECR_REPO_PREFIX
#
# Notes:
#   - Default region: us-east-1
#   - Default ECR repo prefix: dapr-eks-pubsub
#   - Requires: aws, kubectl, eksctl, helm, docker

# -------------------------
# Pretty printing / helpers
# -------------------------
red()    { printf "\033[31m%s\033[0m\n" "$*"; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
blue()   { printf "\033[34m%s\033[0m\n" "$*"; }
hr()     { printf "\n%s\n" "────────────────────────────────────────────────────────"; }

start_ts=$(date +%s)
trap 'red "[ERROR] Orchestration failed"; exit 1' ERR

# -------------------------
# Parse arguments
# -------------------------
ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
REGION="${AWS_REGION:-us-east-1}"
PREFIX="${ECR_REPO_PREFIX:-dapr-eks-pubsub}"
SKIP_CLUSTER="false"
SKIP_BUILD="false"
SKIP_DEPLOY="false"
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --account) shift; ACCOUNT_ID="${1:-}";;
    --region) shift; REGION="${1:-}";;
    --prefix) shift; PREFIX="${1:-}";;
    --skip-cluster) SKIP_CLUSTER="true";;
    --skip-build)   SKIP_BUILD="true";;
    --skip-deploy)  SKIP_DEPLOY="true";;
    --dry-run)      DRY_RUN="true";;
    -h|--help)
      grep '^#' "$0" | sed -e 's/^# \{0,1\}//'
      exit 0;;
    *) yellow "Unknown arg: $1";;
  esac
  shift || true
done

# Prompt for account if not provided
if [[ -z "$ACCOUNT_ID" ]]; then
  read -r -p "Enter AWS Account ID: " ACCOUNT_ID
fi
if [[ -z "$ACCOUNT_ID" ]]; then
  red "AWS Account ID is required. Use --account <id> or set AWS_ACCOUNT_ID."
  exit 1
fi

export AWS_ACCOUNT_ID="$ACCOUNT_ID"
export AWS_REGION="$REGION"
export ECR_REPO_PREFIX="$PREFIX"

blue "Parameters:"
echo "  AWS_ACCOUNT_ID   = $AWS_ACCOUNT_ID"
echo "  AWS_REGION       = $AWS_REGION"
echo "  ECR_REPO_PREFIX  = $ECR_REPO_PREFIX"
echo "  SKIP_CLUSTER     = $SKIP_CLUSTER"
echo "  SKIP_BUILD       = $SKIP_BUILD"
echo "  SKIP_DEPLOY      = $SKIP_DEPLOY"
echo "  DRY_RUN          = $DRY_RUN"
hr

# -------------------------
# Validate tooling
# -------------------------
need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    red "Missing required command: $1"
    exit 1
  fi
}
yellow "Validating prerequisites…"
need aws; need kubectl; need eksctl; need helm; need docker
green "Prereqs OK."
hr

# -------------------------
# Step 1: Cluster + IRSA
# -------------------------
if [[ "$SKIP_CLUSTER" == "false" ]]; then
  blue "[1/3] Create/Ensure EKS cluster with OIDC + IRSA"
  if [[ "$DRY_RUN" == "true" ]]; then
    yellow "DRY-RUN: ./eks/create-cluster.sh $AWS_ACCOUNT_ID"
  else
    ./eks/create-cluster.sh "$AWS_ACCOUNT_ID"
  fi
else
  yellow "Skipping cluster creation (--skip-cluster)"
fi
hr

# -------------------------
# Step 2: Build & Push ECR
# -------------------------
if [[ "$SKIP_BUILD" == "false" ]]; then
  blue "[2/3] Build and push service images to ECR"
  if [[ "$DRY_RUN" == "true" ]]; then
    yellow "DRY-RUN: ./scripts/build_push.sh $AWS_ACCOUNT_ID $AWS_REGION $ECR_REPO_PREFIX"
  else
    ./scripts/build_push.sh "$AWS_ACCOUNT_ID" "$AWS_REGION" "$ECR_REPO_PREFIX"
  fi
else
  yellow "Skipping build/push (--skip-build)"
fi
hr

# -------------------------
# Step 3: Dapr + Deploy
# -------------------------
if [[ "$SKIP_DEPLOY" == "false" ]]; then
  blue "[3/3] Install Dapr and deploy microservices"
  if [[ "$DRY_RUN" == "true" ]]; then
    yellow "DRY-RUN: ./scripts/deploy.sh"
  else
    ./scripts/deploy.sh
  fi
else
  yellow "Skipping deploy (--skip-deploy)"
fi
hr

# -------------------------
# Summary
# -------------------------
end_ts=$(date +%s)
elapsed=$(( end_ts - start_ts ))
green "All done in ${elapsed}s."
echo "Next:"
echo "  kubectl -n dapr-apps logs deploy/orderservice -f"
echo "  # Re-run publish test if desired:"
echo "  kubectl -n dapr-apps port-forward deploy/productservice 18080:8080 &"
echo "  curl -X POST http://localhost:18080/publish -H 'Content-Type: application/json' -d '{\"orderId\": 7, \"item\":\"demo\"}'
#
if
you
pasted
somewhere
else
