
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
# 3b) CloudFormation stacks cleanup (eksctl)
# =========================
log "Cleaning up eksctl CloudFormation stacks…"

# Discover expected stack names for this cluster
CLUSTER_STACK="eksctl-${CLUSTER_NAME}-cluster"

# Find all nodegroup stacks for this cluster
NODEGROUP_STACKS=$(aws cloudformation list-stacks \
  --region "$REGION" --profile "$AWS_PROFILE" \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE DELETE_FAILED DELETE_IN_PROGRESS ROLLBACK_COMPLETE ROLLBACK_IN_PROGRESS \
  --query "StackSummaries[?contains(StackName, 'eksctl-${CLUSTER_NAME}-nodegroup-')].StackName" \
  --output text 2>/dev/null || echo "")

# Helper: disable termination protection if enabled
disable_tp() {
  local stack_name="$1"
  if [[ -n "$stack_name" ]]; then
    aws cloudformation update-termination-protection \
      --no-enable-termination-protection \
      --stack-name "$stack_name" \
      --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true
  fi
}

# Helper: delete a stack and wait for completion
delete_stack_and_wait() {
  local stack_name="$1"
  if [[ -n "$stack_name" ]]; then
    log "Deleting stack: $stack_name"
    aws cloudformation delete-stack \
      --stack-name "$stack_name" \
      --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true
    # Wait (best-effort)
    aws cloudformation wait stack-delete-complete \
      --stack-name "$stack_name" \
      --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true
  fi
}

# 1) Delete nodegroup stacks first (they export/import values from the cluster stack)
if [[ -n "$NODEGROUP_STACKS" && "$NODEGROUP_STACKS" != "None" ]]; then
  for ng_stack in $NODEGROUP_STACKS; do
    log "Preparing nodegroup stack: $ng_stack"
    disable_tp "$ng_stack"
    delete_stack_and_wait "$ng_stack"
  done
else
  warn "No eksctl nodegroup stacks found for cluster '$CLUSTER_NAME'."
fi

# 2) Now delete the cluster control plane stack
#    (do this even if EKS cluster was already deleted via API)
#    This cleans up VPC, SGs, roles, and exported outputs left by eksctl.
log "Preparing cluster stack: $CLUSTER_STACK"
disable_tp "$CLUSTER_STACK"
delete_stack_and_wait "$CLUSTER_STACK"

log "eksctl CloudFormation stacks cleanup complete."


# =========================
# 3c) Optional hardening: resolve VPC blockers if CFN delete fails
# =========================
# This block runs ONLY if the eksctl cluster stack deletion failed.
# It cleans common blockers inside the VPC, then re-attempts CFN deletion.
# Safe: does nothing unless DELETE_FAILED.

# Helper: get current stack status (returns empty if stack is gone)
get_stack_status() {
  local stack_name="$1"
  aws cloudformation describe-stacks \
    --stack-name "$stack_name" \
    --region "$REGION" --profile "$AWS_PROFILE" \
    --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo ""
}

STACK_STATUS="$(get_stack_status "$CLUSTER_STACK")"
if [[ "$STACK_STATUS" == "DELETE_FAILED" ]]; then
  warn "Cluster stack '$CLUSTER_STACK' deletion FAILED. Attempting to clear VPC dependencies and retry…"

  # Obtain VPC ID from the stack outputs
  VPC_ID="$(aws cloudformation describe-stacks \
    --stack-name "$CLUSTER_STACK" \
    --region "$REGION" --profile "$AWS_PROFILE" \
    --query "Stacks[0].Outputs[?OutputKey=='VPC'].OutputValue | [0]" \
    --output text 2>/dev/null || echo "")"

  if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    warn "Could not resolve VPC ID from stack outputs. Skipping hardening."
  else
    log "Hardening: cleaning resources in VPC $VPC_ID"

    # 1) Delete Load Balancers (ALB/NLB) in the VPC
    LB_ARNS="$(aws elbv2 describe-load-balancers \
      --region "$REGION" --profile "$AWS_PROFILE" \
      --query "LoadBalancers[?VpcId=='${VPC_ID}'].LoadBalancerArn" \
      --output text 2>/dev/null || echo "")"
    if [[ -n "$LB_ARNS" && "$LB_ARNS" != "None" ]]; then
      for arn in $LB_ARNS; do
        log "Deleting ELBv2 load balancer: $arn"
        aws elbv2 delete-load-balancer \
          --load-balancer-arn "$arn" \
          --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true
      done
      # Wait briefly for ENIs/SGs to detach
      sleep 20
    fi

    # 2) Detach and delete Internet Gateways
    IGW_IDS="$(aws ec2 describe-internet-gateways \
      --region "$REGION" --profile "$AWS_PROFILE" \
      --query "InternetGateways[?Attachments[?VpcId=='${VPC_ID}']].InternetGatewayId" \
      --output text 2>/dev/null || echo "")"
    for igw in $IGW_IDS; do
      log "Detaching and deleting IGW: $igw"
      aws ec2 detach-internet-gateway \
        --internet-gateway-id "$igw" --vpc-id "$VPC_ID" \
        --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true
      aws ec2 delete-internet-gateway \
        --internet-gateway-id "$igw" \
        --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true
    done

    # 3) Delete NAT Gateways + release associated Elastic IPs
    NAT_IDS="$(aws ec2 describe-nat-gateways \
      --filter Name=vpc-id,Values="$VPC_ID" \
      --region "$REGION" --profile "$AWS_PROFILE" \
      --query "NatGateways[].NatGatewayId" --output text 2>/dev/null || echo "")"
    for nat in $NAT_IDS; do
      log "Deleting NAT Gateway: $nat"
      aws ec2 delete-nat-gateway \
        --nat-gateway-id "$nat" \
        --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true
    done
    # Wait for NATs to delete (they can take time)
    if [[ -n "$NAT_IDS" && "$NAT_IDS" != "None" ]]; then
      log "Waiting up to 2 minutes for NAT Gateways to be removed…"
      sleep 120
    fi
    # Release unattached EIPs in this region (best-effort)
    EIP_ALLOCS="$(aws ec2 describe-addresses \
      --region "$REGION" --profile "$AWS_PROFILE" \
      --query "Addresses[?AssociationId==null].AllocationId" \
      --output text 2>/dev/null || echo "")"
    for alloc in $EIP_ALLOCS; do
      log "Releasing Elastic IP allocation: $alloc"
      aws ec2 release-address \
        --allocation-id "$alloc" \
        --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true
    done

    # 4) Delete non-main route tables
    RT_IDS="$(aws ec2 describe-route-tables \
      --filters Name=vpc-id,Values="$VPC_ID" \
      --region "$REGION" --profile "$AWS_PROFILE" \
      --query "RouteTables[?Associations[?Main!=`true`]].RouteTableId" \
      --output text 2>/dev/null || echo "")"
    for rt in $RT_IDS; do
      log "Deleting route table: $rt"
      aws ec2 delete-route-table \
        --route-table-id "$rt" \
        --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true
    done

    # 5) Delete orphan ENIs in the VPC (best-effort)
    ENI_IDS="$(aws ec2 describe-network-interfaces \
      --filters Name=vpc-id,Values="$VPC_ID" \
      --region "$REGION" --profile "$AWS_PROFILE" \
      --query "NetworkInterfaces[?Status=='available'].NetworkInterfaceId" \
      --output text 2>/dev/null || echo "")"
    for eni in $ENI_IDS; do
      log "Deleting available ENI: $eni"
      aws ec2 delete-network-interface \
        --network-interface-id "$eni" \
        --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true
    done

    # 6) Delete subnets (if any remain)
    SUBNET_IDS="$(aws ec2 describe-subnets \
      --filters Name=vpc-id,Values="$VPC_ID" \
      --region "$REGION" --profile "$AWS_PROFILE" \
      --query "Subnets[].SubnetId" --output text 2>/dev/null || echo "")"
    for sn in $SUBNET_IDS; do
      log "Deleting subnet: $sn"
      aws ec2 delete-subnet \
        --subnet-id "$sn" \
        --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true
    done

    # 7) Delete non-default security groups
    SG_IDS="$(aws ec2 describe-security-groups \
      --filters Name=vpc-id,Values="$VPC_ID" \
      --region "$REGION" --profile "$AWS_PROFILE" \
      --query "SecurityGroups[?GroupName!='default'].GroupId" \
      --output text 2>/dev/null || echo "")"
    for sg in $SG_IDS; do
      log "Deleting security group: $sg"
      aws ec2 delete-security-group \
        --group-id "$sg" \
        --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true
    done

    # Final re-attempt: disable TP and delete stack again
    log "Retrying deletion of cluster stack: $CLUSTER_STACK"
    disable_tp "$CLUSTER_STACK"
    delete_stack_and_wait "$CLUSTER_STACK"
  fi
fi



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

