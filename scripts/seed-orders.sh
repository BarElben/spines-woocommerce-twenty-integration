#!/bin/bash
set -e
cd "$(dirname "$0")/.."
source .env

ADMIN="${1:?Usage: ./seed-orders.sh YOUR-WP-ADMIN-USERNAME}"

WP() {
  docker run --rm --network spines_default \
    -v spines_wp_data:/var/www/html \
    -e WORDPRESS_DB_HOST=wordpress-db \
    -e WORDPRESS_DB_USER=wordpress \
    -e WORDPRESS_DB_PASSWORD=$WP_DB_PASSWORD \
    -e WORDPRESS_DB_NAME=wordpress \
    wordpress:cli wp "$@"
}

echo "== Looking up products by SKU =="
PROOF_ID=$(WP wc product list --sku=SRV-PROOF --field=id --user=$ADMIN)
AUDIO_ID=$(WP wc product list --sku=ADDON-AUDIO --field=id --user=$ADMIN)
PKG_ID=$(WP wc product list --sku=PKG-ESS --field=parent_id --user=$ADMIN)
[ -z "$PKG_ID" ] || [ "$PKG_ID" = "0" ] && PKG_ID=$(WP wc product list --search="Book Publishing Package" --field=id --user=$ADMIN | head -1)
SIG_ID=$(WP wc product_variation list $PKG_ID --fields=id,sku --format=csv --user=$ADMIN | grep PKG-SIG | cut -d, -f1)
ESS_ID=$(WP wc product_variation list $PKG_ID --fields=id,sku --format=csv --user=$ADMIN | grep PKG-ESS | cut -d, -f1)
echo "Proofreading=$PROOF_ID Audiobook=$AUDIO_ID Package=$PKG_ID Signature=$SIG_ID Essential=$ESS_ID"

echo "== Customer: Alice (registered) =="
ALICE_ID=$(WP user create alice alice.author@example.com --role=customer \
  --first_name=Alice --last_name=Author --porcelain 2>/dev/null || WP user get alice --field=ID)
echo "Alice user id: $ALICE_ID"

echo "== Order 1: Alice - Signature package + Audiobook add-on =="
WP wc shop_order create --user=$ADMIN --status=processing --customer_id=$ALICE_ID \
  --billing='{"first_name":"Alice","last_name":"Author","email":"alice.author@example.com"}' \
  --line_items="[{\"product_id\":$PKG_ID,\"variation_id\":$SIG_ID,\"quantity\":1},{\"product_id\":$AUDIO_ID,\"quantity\":1}]"

echo "== Order 2: Alice returns - Proofreading =="
WP wc shop_order create --user=$ADMIN --status=processing --customer_id=$ALICE_ID \
  --billing='{"first_name":"Alice","last_name":"Author","email":"alice.author@example.com"}' \
  --line_items="[{\"product_id\":$PROOF_ID,\"quantity\":1}]"

echo "== Order 3: Dan (guest) - Proofreading + Essential package =="
WP wc shop_order create --user=$ADMIN --status=processing --customer_id=0 \
  --billing='{"first_name":"Dan","last_name":"Reader","email":"dan.reader@example.com"}' \
  --line_items="[{\"product_id\":$PROOF_ID,\"quantity\":1},{\"product_id\":$PKG_ID,\"variation_id\":$ESS_ID,\"quantity\":1}]"

echo "== Done. Three orders created in Processing status =="
