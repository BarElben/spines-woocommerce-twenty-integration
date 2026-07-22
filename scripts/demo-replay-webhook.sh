#!/bin/bash
# demo-replay-webhook.sh — engineered trigger for the "duplicate webhook delivery"
# demonstration scenario (category 7).
#
# What it does: fetches the REAL current JSON for a WooCommerce order (the same
# resource shape WooCommerce sends as an order.updated webhook payload), computes
# a valid x-wc-webhook-signature over those exact bytes using the real
# WC_WEBHOOK_SECRET, and POSTs that identical body+signature to the n8n webhook
# URL N times in a row (default 2). This simulates WooCommerce (or a network
# retry) delivering the *same* webhook event twice — the sync chain must produce
# zero duplicate records on the second delivery.
#
# Usage:
#   ./scripts/demo-replay-webhook.sh <order_id> [times] [--dry-run]
#
# Prereqs: order <order_id> must already exist and be status=completed (run the
# normal create+complete WP-CLI flow first — that first natural completion is
# "delivery #1"; this script re-sends the same payload as delivery #2, #3, ...).
#
# --dry-run: computes and prints the signature + curl command but does NOT
# actually send anything. Use this to sanity-check before the real demo run.
set -euo pipefail
cd "$(dirname "$0")/.."
source .env

ORDER_ID="${1:?Usage: $0 <order_id> [times] [--dry-run]}"
TIMES="${2:-2}"
DRY_RUN=0
for a in "$@"; do [ "$a" = "--dry-run" ] && DRY_RUN=1; done

ADMIN_USER="${WP_ADMIN_USER:-1}"
WEBHOOK_URL="https://${DOMAIN_N8N}/webhook/woocommerce-orders"

WP() {
  docker run --rm --network spines_default \
    -v spines_wp_data:/var/www/html \
    -e WORDPRESS_DB_HOST=wordpress-db \
    -e WORDPRESS_DB_USER=wordpress \
    -e WORDPRESS_DB_PASSWORD="$WP_DB_PASSWORD" \
    -e WORDPRESS_DB_NAME=wordpress \
    wordpress:cli wp "$@"
}

echo "== Fetching real order #$ORDER_ID JSON (this is the exact payload shape WooCommerce sends) =="
BODY_FILE=$(mktemp)
WP wc shop_order get "$ORDER_ID" --user="$ADMIN_USER" --format=json > "$BODY_FILE"

STATUS=$(python3 -c "import json;print(json.load(open('$BODY_FILE'))['status'])")
if [ "$STATUS" != "completed" ]; then
  echo "ERROR: order $ORDER_ID is status='$STATUS', not 'completed'. Complete it first." >&2
  rm -f "$BODY_FILE"
  exit 1
fi
echo "Order $ORDER_ID confirmed status=completed. Body size: $(wc -c < "$BODY_FILE") bytes."

echo "== Computing HMAC-SHA256 signature (base64) over the exact body bytes =="
SIGNATURE=$(openssl dgst -sha256 -hmac "$WC_WEBHOOK_SECRET" -binary < "$BODY_FILE" | base64)
echo "Signature computed (not printed — sensitive derived value)."

echo "== Replaying identical payload $TIMES time(s) to $WEBHOOK_URL =="
for i in $(seq 1 "$TIMES"); do
  echo "--- delivery attempt $i/$TIMES ---"
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] would POST $BODY_FILE to $WEBHOOK_URL with x-wc-webhook-signature header"
    continue
  fi
  HTTP_CODE=$(curl -s -o /tmp/replay_resp_$i.json -w "%{http_code}" -X POST "$WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -H "x-wc-webhook-topic: order.updated" \
    -H "x-wc-webhook-resource: order" \
    -H "x-wc-webhook-event: updated" \
    -H "x-wc-webhook-signature: $SIGNATURE" \
    -H "User-Agent: WooCommerce-Hookshot/demo-replay" \
    --data-binary @"$BODY_FILE")
  echo "HTTP status: $HTTP_CODE (response saved to /tmp/replay_resp_$i.json)"
done

rm -f "$BODY_FILE"
echo "== Done. Now verify in Twenty: exactly ONE Order record for Woo Order Number=$ORDER_ID, and exactly the original set of Order Line Items (no doubling). =="
