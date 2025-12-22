#!/usr/bin/env bash
set -euo pipefail

echo "==> Deploying Dapr components and applications"

# Apply namespace and service account
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-serviceaccount.yaml

# Apply Dapr components
kubectl apply -f dapr/snssqs-pubsub.yaml
kubectl apply -f dapr/subscription-orders.yaml

# Deploy applications
kubectl apply -f k8s/10-productservice.yaml
kubectl apply -f k8s/11-orderservice.yaml

echo "==> Waiting for deployments to be ready..."
kubectl wait --for=condition=Available deployment/productservice -n dapr-apps --timeout=300s
kubectl wait --for=condition=Available deployment/orderservice -n dapr-apps --timeout=300s

echo "==> Deployment complete!"
kubectl get pods -n dapr-apps -o wide