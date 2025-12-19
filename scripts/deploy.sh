
#!/usr/bin/env bash
set -euo pipefail

# Install Dapr via Helm if not installed
if ! kubectl get ns dapr-system >/dev/null 2>&1; then
  helm repo add dapr https://dapr.github.io/helm-charts/
  helm repo update
  helm upgrade --install dapr dapr/dapr --namespace dapr-system --create-namespace --wait
fi

# Create namespace & apply SA (IRSA assumed to be attached via eksctl)
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-serviceaccount.yaml

# Apply Dapr component and subscription
kubectl apply -f dapr/snssqs-pubsub.yaml
kubectl apply -f k8s/20-subscription.yaml

# Deploy apps
kubectl apply -f k8s/10-productservice.yaml
kubectl apply -f k8s/11-orderservice.yaml

kubectl -n dapr-apps rollout status deploy/productservice --timeout=180s
kubectl -n dapr-apps rollout status deploy/orderservice --timeout=180s

echo "Deployed. Test publishing:"
PRODUCT_POD=$(kubectl -n dapr-apps get pod -l app=productservice -o jsonpath='{.items[0].metadata.name}')
kubectl -n dapr-apps port-forward pod/${PRODUCT_POD} 18080:8080 >/dev/null 2>&1 & PF_PID=$!
sleep 2
curl -s -X POST http://localhost:18080/publish -H 'Content-Type: application/json' -d '{"orderId": 1001, "item":"widget"}' || true
sleep 3
kill ${PF_PID} || true

echo "Check logs: kubectl -n dapr-apps logs deploy/orderservice"
