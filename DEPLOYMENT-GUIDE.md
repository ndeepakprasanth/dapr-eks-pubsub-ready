# Deployment Guide - Fixed and Production Ready
**Author**: Deepak  
**Date**: December 22, 2025

## What Was Fixed

### 1. Prerequisites Validation
- Created `check-prerequisites.sh` to validate all requirements before deployment
- Checks: AWS CLI, kubectl, eksctl, Helm, Docker, AWS credentials, permissions

### 2. OIDC Provider Setup
- Fixed missing OIDC provider for IRSA (IAM Roles for Service Accounts)
- Automatically creates OIDC provider if it doesn't exist
- Required for EBS CSI driver and other AWS integrations

### 3. EBS CSI Driver Configuration
- Added complete IAM role setup for EBS CSI driver
- Creates service account with proper annotations
- Installs addon with correct permissions
- Enables persistent volumes for Dapr scheduler

### 4. AWS Profile Support
- Added AWS_PROFILE support throughout all scripts
- Defaults to "Deepak" profile for lab environment
- Can be overridden: `AWS_PROFILE=YourProfile ./oneclick.sh`

### 5. Error Handling
- Added proper error checking and retries
- Waits for resources to be ready before proceeding
- Provides clear status messages

## How to Use

### Step 1: Validate Prerequisites
```bash
./check-prerequisites.sh
```

### Step 2: Deploy Everything
```bash
ACCOUNT_ID=946248011760 ./oneclick.sh
```

### Step 3: Test the System
```bash
./test.sh
```

## What Gets Deployed

1. **EKS Cluster** (dapr-eks)
   - 2 t3.medium nodes
   - OIDC provider enabled
   - EBS CSI driver installed

2. **Dapr Control Plane**
   - Operator, Placement, Sentry
   - Sidecar Injector
   - Scheduler (with persistent storage)

3. **Applications**
   - ProductService (publisher)
   - OrderService (subscriber)
   - Both with Dapr sidecars (2/2 Ready)

4. **AWS Resources**
   - ECR repositories with images
   - IAM roles and policies
   - SNS/SQS for pub/sub (auto-created by Dapr)

## Expected Timeline

- **EKS Cluster Creation**: 10-12 minutes
- **Dapr Installation**: 3-5 minutes
- **Image Build & Push**: 3-5 minutes
- **Application Deployment**: 1-2 minutes
- **Total**: ~20-25 minutes

## Verification Commands

```bash
# Check all pods
kubectl get pods -n dapr-apps -o wide
kubectl get pods -n dapr-system

# Check services
kubectl get svc -n dapr-apps

# Check Dapr components
kubectl get components -n dapr-apps

# Check ECR images
aws ecr describe-repositories --region us-east-1 --profile Deepak
```

## Cleanup

```bash
./destroy.sh
```

## Troubleshooting

If oneclick.sh fails:
1. Check prerequisites: `./check-prerequisites.sh`
2. Verify AWS credentials: `aws sts get-caller-identity --profile Deepak`
3. Check EKS cluster: `kubectl get nodes`
4. Review logs in the terminal output

## Files Updated

- `oneclick.sh` - Complete deployment automation
- `check-prerequisites.sh` - Prerequisites validation
- `scripts/build_push.sh` - AWS profile support
- `README.md` - Updated documentation
- `ARCHITECTURE.md` - Architecture diagram

All files are production-ready and tested!