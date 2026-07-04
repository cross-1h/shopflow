#!/usr/bin/env bash
# Post-deploy smoke test. Confirms the live system answers after a deploy.
# Usage: ./smoke-test.sh https://shop.YOURDOMAIN.com
set -euo pipefail

BASE="${1:?Usage: ./smoke-test.sh <base-url>}"

echo "1. Catalog returns products..."
PRODUCTS=$(curl -fsS "${BASE}/api/catalog/products")
echo "   got: $(echo "$PRODUCTS" | head -c 120)..."

FIRST_ID=$(echo "$PRODUCTS" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
echo "2. Placing an order for product ${FIRST_ID}..."
ORDER=$(curl -fsS -X POST "${BASE}/api/orders" \
  -H 'Content-Type: application/json' \
  -d "{\"productId\": ${FIRST_ID}, \"quantity\": 1}")
echo "   order response: ${ORDER}"

echo "SMOKE TEST PASSED"
