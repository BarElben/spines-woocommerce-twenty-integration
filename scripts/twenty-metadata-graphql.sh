#!/bin/bash
# twenty-metadata-graphql.sh — run a GraphQL query/mutation against Twenty's
# METADATA endpoint (/metadata), as opposed to the regular /graphql endpoint
# that scripts/demo-twenty-graphql.sh targets.
#
# Why this exists / when to use it: most workflow-editor mutations
# (createWorkflowVersionStep, updateWorkflowVersionStep, deleteWorkflowVersionStep,
# saveImapSmtpCaldavAccount, ...) live on /metadata AND require a real logged-in
# user session (UserAuthGuard) — an API key cannot call them ("Forbidden
# resource"), confirmed by direct testing (see PROGRESS.md category 6 notes).
#
# BUT a few /metadata mutations only require WorkspaceAuthGuard +
# SettingsPermissionGuard(WORKFLOWS) — no UserAuthGuard — so an API key CAN
# call them. Confirmed working: findOneLogicFunction, findManyLogicFunctions,
# updateOneLogicFunction (edits a Logic/Code step's source code + its
# workflowActionTriggerSettings.inputSchema). This is the exact same mutation
# Twenty's own front-end calls when you edit code in the Code step's editor —
# a real application-level path, not a raw DB/JSONB bypass.
#
# Still NOT reachable via API key (verified): anything on
# WorkflowVersionStepResolver (the step wiring/mapping/deletion itself) or
# saveImapSmtpCaldavAccount — those need a real browser session.
#
# Usage:
#   ./scripts/twenty-metadata-graphql.sh '<query or mutation>' ['<variables json>']
#
# Example (read logic function inputSchema):
#   ./scripts/twenty-metadata-graphql.sh \
#     'query($id: ID!) { findOneLogicFunction(input: {id: $id}) { id name workflowActionTriggerSettings } }' \
#     '{"id": "67e154a5-a5f4-4385-a94a-16f14a27a041"}'
#
# Prints the raw JSON response to stdout. Uses the same container-hop pattern
# as demo-twenty-graphql.sh (via the n8n container, which already holds
# TWENTY_API_KEY / TWENTY_API_URL) — never reads host .env, never prints a
# secret.
set -euo pipefail
cd "$(dirname "$0")/.."

QUERY="${1:?Usage: $0 '<graphql query or mutation string>' ['<variables json>']}"
VARS="${2:-}"
if [ -z "$VARS" ]; then
  VARS='{}'
fi

TMP_HOST=$(mktemp)
python3 -c "
import json, sys
query = sys.argv[1]
variables = json.loads(sys.argv[2])
print(json.dumps({'query': query, 'variables': variables}))
" "$QUERY" "$VARS" > "$TMP_HOST"

docker compose cp "$TMP_HOST" n8n:/tmp/twenty-metadata-payload.json
docker compose exec -T n8n sh -c 'wget -qO- --header="Authorization: Bearer $TWENTY_API_KEY" --header="Content-Type: application/json" --post-file=/tmp/twenty-metadata-payload.json "$TWENTY_API_URL/metadata"; echo'
docker compose exec -T n8n rm -f /tmp/twenty-metadata-payload.json
rm -f "$TMP_HOST"
