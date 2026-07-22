#!/bin/bash
# demo-retrigger-webhook.sh — fires a NATURAL fresh order.updated webhook for an
# order that is already status=completed, without recreating the order or
# faking any payload. Used by two demo scenarios (category 7):
#
#   1. "Fail partway then retry": after a node in the n8n sync chain has been
#      deliberately broken and the first completion attempt has errored out
#      partway through (Order created, Line Items not yet), this script
#      re-fires the webhook so the retry attempt runs after the node is fixed.
#   2. As a simpler alternative to demo-replay-webhook.sh for "duplicate
#      webhook delivery" if you'd rather demonstrate it with two genuinely
#      separate WooCommerce-triggered deliveries instead of a byte-identical
#      curl replay (both are valid interpretations of the assignment; the
#      replay script is closer to "same webhook", this one is closer to
#      "WooCommerce re-sent an update for the same order").
#
# How it works: WooCommerce's order.updated webhook fires on ANY save of the
# order object via woocommerce_update_order, not only on a status transition.
# Updating customer_note to a fresh timestamped value forces a real save
# without altering anything the sync chain reads (status/line_items/billing/
# totals all stay exactly as they were), so the resulting webhook has the same
# meaningful content as the original delivery.
#
# Usage:
#   ./scripts/demo-retrigger-webhook.sh <order_id>
set -euo pipefail
cd "$(dirname "$0")/.."
source .env

ORDER_ID="${1:?Usage: $0 <order_id>}"
ADMIN_USER="${WP_ADMIN_USER:-1}"

WP() {
  docker run --rm --network spines_default \
    -v spines_wp_data:/var/www/html \
    -e WORDPRESS_DB_HOST=wordpress-db \
    -e WORDPRESS_DB_USER=wordpress \
    -e WORDPRESS_DB_PASSWORD="$WP_DB_PASSWORD" \
    -e WORDPRESS_DB_NAME=wordpress \
    wordpress:cli wp "$@"
}

STAMP=$(date +%s)
echo "== Confirming order $ORDER_ID is currently status=completed =="
CURRENT_STATUS=$(WP wc shop_order get "$ORDER_ID" --user="$ADMIN_USER" --format=json | python3 -c "import json,sys;print(json.load(sys.stdin)['status'])")
if [ "$CURRENT_STATUS" != "completed" ]; then
  echo "ERROR: order $ORDER_ID is status='$CURRENT_STATUS', not 'completed'. This script expects an already-completed order (it re-fires the event, it doesn't create the initial completion)." >&2
  exit 1
fi

echo "== Forcing a fresh order.updated webhook via a no-op customer_note save (order stays completed) =="
WP wc shop_order update "$ORDER_ID" --customer_note="demo re-trigger $STAMP" --user="$ADMIN_USER"

echo "== Done. A new order.updated webhook should have been delivered to n8n just now."
echo "   Check n8n Executions for a fresh execution against order $ORDER_ID."
echo "   (If WooCommerce optimizes away no-field-change saves in some version and no webhook"
echo "    fires, fall back to: wp wc shop_order update $ORDER_ID --status=completed --user=$ADMIN_USER"
echo "    which forces a REST update call regardless.)"
