#!/bin/bash
# demo-twenty-graphql.sh — run a GraphQL query/mutation against Twenty from
# the host, by proxying through the n8n container.
#
# Why: Twenty's GraphQL endpoint (http://twenty-server:3000/graphql) is
# container-internal only — not published to the host — so every scenario in
# this demo queries/mutates Twenty by exec-ing into a container that's already
# on the spines_default network and already holds the API key. n8n is used
# because its environment already has both TWENTY_API_KEY and
# TWENTY_API_URL=http://twenty-server:3000 set (see docker-compose.yml's n8n
# service) — this script relies on THAT container-internal env, so it never
# reads .env on the host and never prints a secret to the terminal.
#
# Usage:
#   ./scripts/demo-twenty-graphql.sh '<graphql query or mutation string>'
#
# Example:
#   ./scripts/demo-twenty-graphql.sh 'query { opportunities(filter: {id: {eq: "8e9d9e20-e060-4086-8461-694fb2c5b0e6"}}) { edges { node { id name amount { amountMicros currencyCode } arr { amountMicros currencyCode } } } } }'
#
# Prints the raw JSON response to stdout. Non-zero exit if docker compose
# itself fails; a GraphQL-level error still prints as JSON with an "errors"
# key (check output by eye / grep for '"errors"').
set -euo pipefail
cd "$(dirname "$0")/.."

QUERY="${1:?Usage: $0 '<graphql query or mutation string>'}"

TMP_HOST=$(mktemp)
python3 -c "import json,sys; print(json.dumps({'query': sys.argv[1]}))" "$QUERY" > "$TMP_HOST"

docker compose cp "$TMP_HOST" n8n:/tmp/demo-gql-payload.json
docker compose exec -T n8n sh -c 'wget -qO- --header="Authorization: Bearer $TWENTY_API_KEY" --header="Content-Type: application/json" --post-file=/tmp/demo-gql-payload.json "$TWENTY_API_URL/graphql"; echo'
docker compose exec -T n8n rm -f /tmp/demo-gql-payload.json
rm -f "$TMP_HOST"
