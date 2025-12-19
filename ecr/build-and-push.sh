#!/bin/bash
set -euo pipefail

REGION="us-east-1"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# Ensure directories exist
for d in src/productservice src/orderservice; do
  if [[ ! -d "$d" ]]; then
    echo "ERROR: missing directory: $d"
    exit 1
  fi
done

build_and_push() {
  local svc="$1"
  local path="src/$svc"

  echo ">>> Building $svc from $path"
  pushd "$path" >/dev/null

  docker build -t "$svc:latest" .
  docker tag "$svc:latest" "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$svc:latest"

  echo ">>> Pushing $svc to ECR"
  docker push "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$svc:latest"

  popd >/dev/null
}

build_and_push productservice
build_and_push orderservice

echo ">>> Done. Images:"
echo "    $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/productservice:latest"
echo "    $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/orderservice:latest"
