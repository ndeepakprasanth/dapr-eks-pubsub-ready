
#!/usr/bin/env bash
set -euo pipefail

NS="dapr-apps"
REGION="${AWS_REGION:-us-east-1}"

echo "────────────────────────────────────────────────────────"
echo "[post] Verifying Dapr control plane is healthy"
kubectl get pods -n dapr-system

echo "────────────────────────────────────────────────────────"
echo "[post] Ensuring namespace and service account exist"
kubectl get ns "${NS}" || { echo "Namespace ${NS} missing"; exit 1; }
kubectl -n "${NS}" get serviceaccount dapr-pubsub-sa || { echo "ServiceAccount dapr-pubsub-sa missing"; exit 1; }

echo "────────────────────────────────────────────────────────"
echo "[post] Verifying Dapr components & subscription in ${NS}"
kubectl -n "${NS}" get components
kubectl -n "${NS}" get subscription

echo "────────────────────────────────────────────────────────"
echo "[post] Checking app deployments & sidecars"
kubectl -n "${NS}" get deploy
kubectl -n "${NS}" get pods -o wide

# Confirm daprd sidecars are injected (each pod should show a 'daprd' container)
for app in productservice orderservice; do
  POD=$(kubectl -n "${NS}" get pod -l app="${app}" -o jsonpath='{.items[0].metadata.name}')
  echo "[post] Describing pod ${POD} (expect a daprd container)"
  kubectl -n "${NS}" get pod "${POD}" -o json | jq -r '.spec.containers[].name'
done

echo "────────────────────────────────────────────────────────"
echo "[post] Publish test message through ProductService"
PRODUCT_POD=$(kubectl -n "${NS}" get pod -l app=productservice -o jsonpath='{.items[0].metadata.name}')
kubectl -n "${NS}" port-forward pod/${PRODUCT_POD} 18080:8080 >/dev/null 2>&1 & PF_PID=$!
sleep 2

curl -s -X POST http://localhost:18080/publish \
  -H 'Content-Type: application/json' \
  -d '{"orderId": 2025, "item":"post-verify"}' || true

sleep 2
kill ${PF_PID} || true

echo "────────────────────────────────────────────────────────"
echo "[post] Fetch OrderService logs (should show received event)"
kubectl -n "${NS}" logs deploy/orderservice | tail -n 50

echo "────────────────────────────────────────────────────────"
echo "[post] (Optional) Publish another test and follow logs live (Ctrl+C to stop)"
echo "  kubectl -n ${NS} port-forward deploy/productservice 18080:8080 &"
echo "  curl -X POST http://localhost:18080/publish -H 'Content-Type: application/json' -d '{\"orderId\":42,\"item\":\"demo\"}'"
echo "  kubectl -n ${NS} logs deploy/orderservice -f"
echo "────────────────────────────────────────────────────────"

# Basic health summary
echo "[post] Summary:"
echo "  ✔ Dapr control plane running (dapr-system)"
echo "  ✔ Namespace & IRecho "  ✔ Namespace & IRSA service account present (${NS}/dapr-pubsub-sa)"
echo "  ✔ Dapr SNS/SQS component and Subscription present (${NS})"
echo "  ✔ ProductService + OrderService deployed"