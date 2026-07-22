# Spines — WooCommerce → Twenty CRM Integration

## Mission
Engineering project for Spines (book publishing platform). Build and deploy:
WooCommerce order reaches Completed → webhook → n8n workflow → sync customer,
order, products, quantities, prices, variations, add-ons into self-hosted Twenty CRM.
Deliverables: git repo (compose + proxy config, .env.example, exported n8n workflow,
postgres init scripts, README with architecture/data model/dedup+retry approach/
limitations). 

## Infrastructure (DONE)
- AWS EC2 t3.medium, Ubuntu 24.04, eu-central-1, Elastic IP 63.181.247.69
- Security: SSH port 22 restricted to owner IPv4 /32 (ISP is IPv6-first — rule needs
  occasional refresh via `curl -4 ifconfig.me`), 80/443 open, nothing else
- Everything in Docker Compose in ~/spines: caddy (ONLY public container, auto-HTTPS),
  n8n + n8n-db (postgres16), twenty-server + twenty-worker + twenty-db (postgres16) +
  redis, wordpress + wordpress-db (mariadb11, in docker-compose.override.yml)
- Domains via sslip.io: n8n.63-181-247-69.sslip.io / crm.…/ shop.…
- Secrets in .env (NEVER commit; .env.example needed as deliverable)
- WP-CLI available via `WP()` bash function (defined in ~/.bashrc) — disposable
  wordpress:cli container on network spines_default

## Shop data (DONE)
Products themed on Spines' real catalog:
- Manuscript Proofreading — simple, SKU SRV-PROOF
- Book Publishing Package — variable, attribute Plan: Essential/Signature/Paramount,
  SKUs PKG-ESS/PKG-SIG/PKG-PAR (variations created via CLI, product id 17)
- Audiobook Production — simple, SKU ADDON-AUDIO (paid add-on modeled as a separate
  line item — deliberate decision, Woo core has no native paid add-ons)
Customers: alice (registered, alice.author@example.com, user id 2) + Dan (guest,
dan.reader@example.com, billing-only). Seed script: scripts/seed-orders.sh (reruns
create new orders; orders 30-32 currently staged in Processing).

## CRM data model in Twenty (DONE, created via UI)
- Person (built-in) — match key: email lowercased (works for guest + registered)
- Product (custom) — key: SKU; fields: SKU, Current Price, Description
- Order (custom) — key: Woo Order Number; fields: Total, Order Date,
  Sync Status (select: pending/synced), relation Customer → Person
- Order Line Item (custom) — relations → Order, → Product; fields: Quantity,
  Unit Price, Line Total, Variation; built-in Name = product-name SNAPSHOT as sold
Design rules: upsert-everything (lookup by unique key, create only if missing) makes
retries safe; snapshot on line items preserves history; Sync Status flips to synced
as the LAST workflow step (idempotent email trigger + resume marker).

## n8n workflow "WooCommerce Order Sync" (webhook gate VERIFIED 2026-07-20;)
Webhook (POST /woocommerce-orders, Raw Body ON) → Code "Verify Signature"
(HMAC-SHA256 of raw body vs x-wc-webhook-signature, timing-safe compare, handles
webhook_id= ping) → IF "Only Completed" (status == completed) 
WooCommerce webhook: topic order.updated, created via WP CLI, delivery to production
URL, secret = WC_WEBHOOK_SECRET.

## Category 4 blocker — RESOLVED 2026-07-20
`.env` secrets were actually already populated (not empty) by the time this session
started — that earlier blocker note was stale. What was actually broken and got
fixed: the Webhook node's `path` was `WooCommerce-orders` (mixed case) while
WooCommerce's real delivery URL uses lowercase `woocommerce-orders` — n8n webhook
paths are case-sensitive, so every real Woo delivery was 404ing. Fixed via
export/edit-path/import + republish + container restart, then removed the stale
mixed-case row left in n8n's `webhook_entity` table. Verified end-to-end against
real signed WooCommerce traffic (order 30 processing→on-hold took the IF false
branch, order 31 on-hold→completed took the IF true branch) and against a forged
signature (correctly rejected with `status=error`, "Invalid webhook signature").
Full detail in PROGRESS.md category 4 notes. TWENTY_API_KEY is present and valid in
.env/n8n — category 5 (sync chain) is unblocked to start.

## Remaining work
1. Sync chain in n8n: upsert Person by email → upsert Products by SKU → upsert Order
   by Woo order number (skip-if-synced) → create line items w/ snapshots → set
   Sync Status=synced last. n8n env has TWENTY_API_URL=http://twenty-server:3000
   (container-to-container) + TWENTY_API_KEY. Twenty API is GraphQL at /graphql
   (+ REST at /rest). NODE_FUNCTION_ALLOW_BUILTIN=crypto already set.
2. Twenty automations (inside Twenty, NOT n8n): (a) email on Sync Status → synced
   with full order summary; (b) ARR field on Opportunity, JS code action:
   ARR = Amount × 12, handle empty/zero, must not re-trigger itself.
3. Demo: 7 scenarios (new customer, returning, multi-product+add-ons, repeated
   product, duplicate webhook delivery, fail-partway-then-retry, both automations).
4. Repo: git init, .gitignore (.env!), .env.example, export workflow JSON,
   postgres init scripts, README, AI-tools disclosure note.

## Conventions
- Explain steps simply — owner is learning; prefer CLI, verifiable outcomes
- Reliable > clever; document every decision + limitations honestly
- Update this file as work progresses (both Claude Code and chat rely on it)

## Agent operating rules
- assignment.md = requirements source of truth; PROGRESS.md = status board.
- Delegate by domain: integration-agent (cat 4-5), crm-automation-agent (6),
  demo-agent (7), docs-agent (8). When an error surfaces, dispatch the agent
  owning that domain to fix it; cross-domain errors come back to the main session.
- Every agent updates PROGRESS.md after working. Honest percentages only —
  verified-working counts, written-but-untested does not.
- When the owner asks for status/percentage: use status-reporter.
- One driver at a time on shared files.

## Safety rules (binding)
- Never delete Docker volumes or containers' data; never run destructive commands
  (rm -rf, docker compose down -v, DROP) without explicit owner approval.
- .env: append/edit single lines only; never rewrite wholesale; never print full
  secret values into logs or chat.
- After completing any task: run the verification, show the evidence, update
  PROGRESS.md. Unverified work is not done.
