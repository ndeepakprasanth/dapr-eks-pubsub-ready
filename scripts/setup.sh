
#!/bin/bash
set -e

echo ">>> Creating EKS cluster..."
eksctl create cluster -f eks/eksctl-cluster.yaml

echo ">>> Installing Dapr..."
helm repo add dapr https://dapr.github.io/helm-charts/
helm repo update
helm upgrade --install dapr dapr/dapr \
  --namespace dapr-system --create-namespace \
  --wait --version 1.16.4

echo ">>> Verifying Dapr pods..."
kubectl get pods -n dapr-system -o wide

