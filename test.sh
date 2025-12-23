#!/usr/bin/env bash
set -euo pipefail

echo "==> Testing Dapr pub/sub functionality"

# Test pub/sub
echo "Publishing test message..."
kubectl -n dapr-apps run test-curl --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 -- \
  curl -X POST http://productservice:8080/publish \
    -H 'Content-Type: application/json' \
    -d '{"orderId": 999, "item":"test-laptop", "price": 1299.99}'


# Wait and verify delivery in OrderService logs
echo "==> Verifying delivery in OrderService logs..."
DELIVERY_FOUND=0
for i in {1..10}; do
  if kubectl -n dapr-apps logs deploy/orderservice --tail=50 | grep -q "OrderService received event:"; then
    echo "Delivery OK: OrderService received the event."
    DELIVERY_FOUND=1
    break
  fi
  sleep 2
done

if [[ $DELIVERY_FOUND -eq 0 ]]; then
  echo "Delivery NOT seen in recent logs."
  exit 1
fi


echo -e "\n==> OrderService logs:"
kubectl -n dapr-apps logs deploy/orderservice --tail=10

echo -e "\n==> Pod status:"
kubectl -n dapr-apps get pods -o wide

echo -e "\n==> Services:"
kubectl -n dapr-apps get svc

echo -e "\n==> Dapr components:"
kubectl -n dapr-apps get components
