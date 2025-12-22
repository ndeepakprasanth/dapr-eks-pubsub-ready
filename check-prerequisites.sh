#!/usr/bin/env bash
# Prerequisites Check for Dapr EKS Assignment
# Author: Deepak

echo "🔍 DAPR EKS ASSIGNMENT - PREREQUISITES CHECK"
echo "============================================="

ACCOUNT_ID="${ACCOUNT_ID:-}"
REGION="${REGION:-us-east-1}"
PROFILE="Deepak"

check_passed=0
check_failed=0

check_requirement() {
    local name="$1"
    local command="$2"
    local fix_hint="$3"
    
    printf "Checking %-20s" "$name..."
    if eval "$command" >/dev/null 2>&1; then
        echo "✓"
        ((check_passed++))
    else
        echo "✗"
        echo "  Fix: $fix_hint"
        ((check_failed++))
    fi
}

echo ""
echo "📋 BASIC TOOLS:"
check_requirement "AWS CLI" "aws --version" "Install AWS CLI v2"
check_requirement "kubectl" "kubectl version --client" "Install kubectl"
check_requirement "eksctl" "eksctl version" "Install eksctl"
check_requirement "Helm" "helm version" "Install Helm 3+"
check_requirement "Docker" "docker --version" "Install Docker"

echo ""
echo "🔐 AWS CONFIGURATION:"
check_requirement "AWS Credentials" "aws sts get-caller-identity --profile $PROFILE" "Configure AWS profile 'Deepak'"
check_requirement "EKS Permissions" "aws eks list-clusters --region $REGION --profile $PROFILE" "Ensure EKS permissions"
check_requirement "ECR Permissions" "aws ecr describe-repositories --region $REGION --profile $PROFILE" "Ensure ECR permissions"
check_requirement "EC2 Permissions" "aws ec2 describe-availability-zones --region $REGION --profile $PROFILE" "Ensure EC2 permissions"

if aws sts get-caller-identity --profile $PROFILE >/dev/null 2>&1; then
    DETECTED_ACCOUNT=$(aws sts get-caller-identity --profile $PROFILE --query Account --output text)
    echo "  Detected Account ID: $DETECTED_ACCOUNT"
fi

echo ""
echo "📊 SUMMARY:"
echo "  ✅ Passed: $check_passed"
echo "  ❌ Failed: $check_failed"

if [[ $check_failed -eq 0 ]]; then
    echo ""
    echo "🎉 ALL PREREQUISITES PASSED!"
    echo "Run: ACCOUNT_ID=$DETECTED_ACCOUNT ./oneclick.sh"
    exit 0
else
    echo ""
    echo "❌ FIX ISSUES ABOVE BEFORE RUNNING oneclick.sh"
    exit 1
fi