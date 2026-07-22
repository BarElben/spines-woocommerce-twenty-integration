# Demo Script — 7 Required Scenarios

Status: **Scenarios 1-6 EXECUTED AND EVIDENCED on 2026-07-20 — see
`demo-results.md` for the actual queries/outputs/execution ids captured.**
Scenario 7 is **drafted and pre-flighted (2026-07-22, demo-agent)** — every
command/mutation below has been written against real, currently-live IDs and
field names (verified read-only against the running stack this session; see
each step's "verified live" note) but **not yet executed**, because it
depends on category 6's two Twenty-internal automations (ARR compute, order-
synced email), which are still being fixed/built by the owner directly in the
Twenty UI as of this writing. The moment category 6 reports done, Scenario 7
should take single-digit minutes: every query is copy-paste ready via
`scripts/demo-twenty-graphql.sh` (new helper, see below), no guessing needed.
One deviation from the original plan, already executed: Scenario 6 used a
**separate temporary n8n workflow** rather than sabotaging the live
production workflow's `Create Line Items` node — see `demo-results.md`'s
Scenario 6 section for why (owner instruction + permission system both
independently ruled out editing the live workflow).

- [x] Category 5's sync chain is built and its exact node names are known —
      confirmed live: Webhook, Verify Signature, Only Completed, Upsert
      Person, Upsert Products, Upsert Order, Already Synced?, Skip - Already
      Synced, Create Line Items, Set Sync Status Synced.
- [ ] Category 6's ARR workflow ("Test lead", id `d39c30af-cfd8-405f-9668-01ced83da150`)
      is active AND correctly wired (Code step input mapped, Update Record
      reads the Code step's output, dead `note`-object steps deleted) — still
      being fixed by the owner as of this writing (its `statuses` column reads
      `{DRAFT,ACTIVE}` live, and its most recent run, checked read-only this
      session, is still `FAILED` — do not treat "Active" alone as "fixed").
- [ ] Category 6's email workflow ("Order Synced Notification" per the agreed
      name) doesn't exist yet — read-only check this session found only 3
      workflow rows total (`Create company when adding a new person`, `Quick
      Lead`, `Test lead`) — still needs to be built from scratch.
- [x] Mailhog mailbox is connected and healthy (`core."connectedAccount"` has
      1 row, `authFailedAt` is `NULL`, per category 6's own notes) — nothing
      to redo there.

## New helper: `scripts/demo-twenty-graphql.sh`

Twenty's GraphQL endpoint is container-internal only (not published to the
host), so every scenario's evidence capture proxies through the `n8n`
container, which already carries `TWENTY_API_KEY`/`TWENTY_API_URL` in its own
environment (see `docker-compose.yml`). Rather than hand-building
`wget --post-data` one-liners with escaped quotes each time (error-prone
under time pressure), this session added a small wrapper:

```bash
./scripts/demo-twenty-graphql.sh '<graphql query or mutation string>'
```

It JSON-encodes the query safely (via `python3 -c "import json..."`, no
manual escaping), copies it into the `n8n` container, posts it to
`http://twenty-server:3000/graphql` with the container's own API key, and
prints the raw JSON response. **Dry-run tested this session** (read-only
query against the fixture Opportunity below) — confirmed working end-to-end,
output included in the query below. Every GraphQL block in Scenario 7 is
meant to be passed to this script verbatim.

## Known IDs / fixtures (verified live, 2026-07-20, read-only)

| Thing | ID / value |
|---|---|
| WP admin (for `--user=` on WP-CLI) | `1` (site admin account) |
| Alice (registered customer) | WP user id `2`, alice.author@example.com |
| Dan (guest customer, pre-existing) | no WP user, billing email dan.reader@example.com |
| Manuscript Proofreading (simple) | product id `13`, SKU `SRV-PROOF`, $499 |
| Audiobook Production (simple, add-on) | product id `14`, SKU `ADDON-AUDIO`, $899 |
| Book Publishing Package (variable, parent) | product id `17` |
| — variation Essential | variation id `27`, SKU `PKG-ESS`, $1490 |
| — variation Signature | variation id `28`, SKU `PKG-SIG`, $3290 |
| — variation Paramount | variation id `29`, SKU `PKG-PAR`, $5990 |
| Existing pre-demo orders (NOT part of demo evidence — see note) | 30 (Alice, on-hold), 31 (Alice, completed, SRV-PROOF), 32 (Dan, completed, SRV-PROOF+PKG-ESS) |
| n8n webhook URL | `https://n8n.63-181-247-69.sslip.io/webhook/woocommerce-orders` |
| n8n production workflow | `WooCommerce Order Sync` (id `OIOadgyS7EXEwyIU`), currently `Webhook → Verify Signature → Only Completed`, sync chain not yet appended |
| Twenty GraphQL (container-internal) | `http://twenty-server:3000/graphql`, reachable via `docker compose exec -T n8n sh -c "wget ..."` or from inside any container on `spines_default` — not published to the host, so query it via `docker compose exec` |
| Twenty currently has | only the 5 seeded demo Persons (Ivan Zhao, Dario Amodei, Brian Chesky, Dylan Field, Patrick Collison) — Alice/Dan do not exist yet, confirmed via live GraphQL query |

**Note on orders 30-32**: these were created by `scripts/seed-orders.sh` and
used by category 4 to verify the webhook gate (signature check, IF branching)
before the sync chain existed. Their historical webhook deliveries already
happened and were correctly *not* processed further (sync chain didn't exist
yet). Treat them as pre-existing shop history, not demo evidence — the 7
scenarios below create **fresh orders** so each one is an unambiguous,
self-contained trigger→evidence pair. (Order 31 is deliberately reused once,
in Scenario 2, as Alice's "prior order" — see below.)

All WP-CLI calls go through the `WP()` bash function pattern already used by
`scripts/seed-orders.sh` (disposable `wordpress:cli` container on
`spines_default`, reads DB creds from `.env`). Every "mark completed" step
follows the pattern proven by category 4: create in `processing`, then a
**separate** `update --status=completed` call, so the tracked `order.updated`
webhook fires cleanly once, distinct from creation.

---

## Scenario 1 — New customer order — [x] EXECUTED, see demo-results.md

**Customer**: Emma Writer, brand-new guest, `emma.writer@example.com` — never
seen in Woo or Twenty before. **Product**: Manuscript Proofreading x1.

```bash
WP wc shop_order create --user=1 --status=processing --customer_id=0 \
  --billing='{"first_name":"Emma","last_name":"Writer","email":"emma.writer@example.com"}' \
  --line_items='[{"product_id":13,"quantity":1}]'
# note the returned order id => ORDER_1
WP wc shop_order update ORDER_1 --status=completed --user=1
```

**Expected n8n evidence**: one new execution, `status=success`, all nodes
green (Webhook → Verify Signature → Only Completed[true] → full sync chain).

**Expected Twenty evidence**:
- New Person "Emma Writer" (emma.writer@example.com) — query
  `people(filter:{emails:{primaryEmail:{eq:"emma.writer@example.com"}}})`,
  expect exactly 1 edge.
- Product SRV-PROOF exists (created here if this is genuinely the first sync
  to touch it — confirm via `products(filter:{sku:{eq:"SRV-PROOF"}})`, expect
  exactly 1 edge, currentPrice 499).
- New Order, Woo Order Number = ORDER_1, Total 499, Sync Status =
  `STATUS_SYNCED`, Customer relation → Emma.
- Exactly 1 Order Line Item linked to that Order: Name "Manuscript
  Proofreading", Quantity 1, Unit Price 499, Line Total 499, Variation empty.

**Capture**: `docker compose exec -T n8n sh -c "wget -qO- --header='Authorization: Bearer $TWENTY_API_KEY' --header='Content-Type: application/json' --post-data='...' http://twenty-server:3000/graphql"` for each check above; screenshot n8n Executions list (execution detail view) and Twenty's Order/Person record pages if a browser is available.

---

## Scenario 2 — Same customer again (returning customer) — [x] EXECUTED, see demo-results.md

**Customer**: Alice (already exists in Woo, does NOT yet exist in Twenty).
Two steps: (2a) establish Alice as an existing synced customer using her
pre-existing order 31; (2b) the actual "returning customer" proof — a brand
new second order.

```bash
# 2a — resync Alice's existing completed order 31 (her "first" order for demo
# purposes) via a no-op field update that forces a fresh order.updated webhook:
./scripts/demo-retrigger-webhook.sh 31

# 2b — Alice places a genuinely new second order (Paramount plan variation):
WP wc shop_order create --user=1 --status=processing --customer_id=2 \
  --billing='{"first_name":"Alice","last_name":"Author","email":"alice.author@example.com"}' \
  --line_items='[{"product_id":17,"variation_id":29,"quantity":1}]'
# note returned order id => ORDER_2
WP wc shop_order update ORDER_2 --status=completed --user=1
```

**Expected n8n evidence**: two successful executions (one for order 31's
resync, one for ORDER_2).

**Expected Twenty evidence**:
- Exactly **one** Person "Alice Author" (alice.author@example.com) after
  BOTH steps — query by email, expect 1 edge, not 2. This is the actual
  dedup proof: the second sync must reuse, not recreate, Alice's Person
  record.
- Two Order records for Alice: Woo Order Number 31 and ORDER_2, both linked
  to the same Person id.
- Product PKG-PAR created for the first time (new SKU); SRV-PROOF reused
  from order 31 (already existed after scenario 1 ran — confirm still
  exactly 1 record).
- Alice's Person → Orders relation (reverse lookup) shows 2 linked orders.

**Capture**: GraphQL query
`people(filter:{emails:{primaryEmail:{eq:"alice.author@example.com"}}}){edges{node{id orders{totalCount}}}}`
— confirm `totalCount` and edge count.

---

## Scenario 3 — Multi-product + add-ons order — [x] EXECUTED, see demo-results.md

**Customer**: Dan (guest, dan.reader@example.com — pre-existing in Woo, not
yet in Twenty). **Products**: Book Publishing Package Signature variation +
Audiobook Production add-on + Manuscript Proofreading, 3 line items, 1 order.

```bash
WP wc shop_order create --user=1 --status=processing --customer_id=0 \
  --billing='{"first_name":"Dan","last_name":"Reader","email":"dan.reader@example.com"}' \
  --line_items='[{"product_id":17,"variation_id":28,"quantity":1},{"product_id":14,"quantity":1},{"product_id":13,"quantity":1}]'
# note returned order id => ORDER_3
WP wc shop_order update ORDER_3 --status=completed --user=1
```

**Expected Twenty evidence**:
- New Person "Dan Reader" (first Dan sync — order 32 was never synced, so
  this is genuinely Dan's first appearance in Twenty).
- Products: PKG-SIG new, ADDON-AUDIO new, SRV-PROOF reused (exists since
  scenario 1/2 — confirm still exactly 1 record, not a 2nd one).
- One Order, Woo Order Number = ORDER_3, Total = 3290+899+499 = 4688.
- **Exactly 3** Order Line Items, all linked to that one Order: package line
  item's Variation field = "Signature".

**Capture**: `orderLineItems(filter:{order:{id:{eq:"<order-id>"}}}){edges{node{name quantity unitPrice{amountMicros} variation}}}` — expect 3 edges.

---

## Scenario 4 — Previously purchased product in a new order (+ historical price integrity) — [x] EXECUTED, see demo-results.md

Bumps SRV-PROOF's price BEFORE the new order, to prove old line items keep
their original snapshot while the new one reflects the new price and the
Product record itself isn't duplicated.

```bash
# Bump the live price:
WP wc product update 13 --regular_price=549 --user=1

# New order, same product, different quantity (also exercises qty handling):
WP wc shop_order create --user=1 --status=processing --customer_id=0 \
  --billing='{"first_name":"Dan","last_name":"Reader","email":"dan.reader@example.com"}' \
  --line_items='[{"product_id":13,"quantity":2}]'
# note returned order id => ORDER_4
WP wc shop_order update ORDER_4 --status=completed --user=1
```

**Expected Twenty evidence**:
- Product SRV-PROOF: still **exactly 1** record (no duplicate on repeated
  SKU), `currentPrice` now 549 (upsert updates the "current" field).
- New Order Line Item on ORDER_4: Quantity 2, Unit Price 549, Line Total
  1098.
- **The historical line item from Scenario 1 (order ORDER_1) must be
  UNCHANGED**: Unit Price still 499, Line Total still 499. This is the key
  proof point for "preserve historical purchase data" — re-query that
  specific line item by id and diff against scenario 1's captured values.

**Capture**: re-run the exact same GraphQL query used in Scenario 1's capture
step against ORDER_1's line item id, confirm byte-identical Unit
Price/Line Total to what was captured then.

---

## Scenario 5 — Same webhook delivered twice (duplicate delivery) — [x] EXECUTED, see demo-results.md

Engineered trigger via `scripts/demo-replay-webhook.sh` (already written and
dry-run tested — see script header for full explanation). It fetches the
real order JSON via WP-CLI (identical shape to what WooCommerce sends),
computes a valid HMAC-SHA256 signature over those exact bytes using the real
`WC_WEBHOOK_SECRET`, and POSTs the byte-identical body+signature to the n8n
webhook URL twice.

```bash
# Dedicated order for isolated evidence:
WP wc shop_order create --user=1 --status=processing --customer_id=0 \
  --billing='{"first_name":"Frank","last_name":"Buyer","email":"frank.buyer@example.com"}' \
  --line_items='[{"product_id":14,"quantity":1}]'
# note returned order id => ORDER_5
WP wc shop_order update ORDER_5 --status=completed --user=1
# ^ this is the natural "delivery #1" (real WooCommerce webhook)

# Now the engineered "delivery #2" (and beyond) — byte-identical replay:
./scripts/demo-replay-webhook.sh ORDER_5 2
# (the "2" here means 2 MORE deliveries via curl, so ORDER_5's webhook is
# delivered 3 times total across this scenario — adjust count as desired;
# even a single extra replay is sufficient to prove the point)
```

**Expected n8n evidence**: 3 total executions for ORDER_5 (1 natural + 2
replayed), all reaching `status=success` (Verify Signature passes on the
replays too — same secret, same bytes, valid signature).

**Expected Twenty evidence — the actual test**: despite 3 successful
executions, **exactly 1** Order record exists for Woo Order Number=ORDER_5,
and **exactly 1** Order Line Item (ADDON-AUDIO, qty 1) — not 2 or 3. The
upsert-by-unique-key design (Woo Order Number on Order, composite match on
line items) must make deliveries 2 and 3 no-ops against already-synced data.

**Capture**: query `orders(filter:{wooOrderNumber:{eq:"ORDER_5"}}){edges{node{id}}}` — count edges, must be 1. Same for line items filtered by that order id.

---

## Scenario 6 — Run failing partway, then succeeding on retry — [x] EXECUTED (via separate temp workflow, not live-workflow sabotage — see demo-results.md)

Engineered trigger: deliberately break one node in the (by-then-built) sync
chain so a real completion run fails **after** the Order is created but
**before** Order Line Items are created, observe the partial state, fix the
node, then retry.

**Step 0 — before touching anything**: export the current working workflow as
a safety net so restoration is exact, not manually re-typed:
```bash
docker compose exec -T n8n n8n export:workflow --id=OIOadgyS7EXEwyIU --output=/tmp/pre-sabotage-backup.json
docker compose cp n8n:/tmp/pre-sabotage-backup.json ./pre-sabotage-backup.json
```

**Step 1 — sabotage**: in the n8n editor, open "WooCommerce Order Sync",
find the node that creates Order Line Items (exact name TBD until category 5
finishes — confirm it live, likely something like "Create Order Line Item").
Temporarily break ONLY that node in a way that produces a real error rather
than being silently skipped — e.g. edit its HTTP Request URL to add an
obvious typo (`/graphql-BROKEN`), or point its credential at an invalid API
key copy. Save (do not need to publish/activate anything differently).

**Step 2 — trigger**: create and complete a dedicated order:
```bash
WP wc shop_order create --user=1 --status=processing --customer_id=0 \
  --billing='{"first_name":"Grace","last_name":"Editor","email":"grace.editor@example.com"}' \
  --line_items='[{"product_id":13,"quantity":1}]'
# note returned order id => ORDER_6
WP wc shop_order update ORDER_6 --status=completed --user=1
```

**Expected evidence of the failure** (before fixing anything):
- n8n execution `status=error`, stopped at the sabotaged node.
- Twenty: Person "Grace Editor" created, Product SRV-PROOF unaffected
  (reused), Order ORDER_6 created with Sync Status **still
  `STATUS_PENDING`** — but **zero** Order Line Items exist yet for it.

**Step 3 — restore**:
```bash
docker compose exec -T n8n n8n import:workflow --input=/tmp/pre-sabotage-backup.json
# then re-publish/activate exactly as it was, restart n8n container if needed
# to reload the webhook registry (per category 4's precedent)
```

**Step 4 — retry**: re-fire the webhook for the same order (it's still
"completed" in Woo, nothing about it changed — this is the actual retry):
```bash
./scripts/demo-retrigger-webhook.sh ORDER_6
```
(Alternative if a browser/n8n API key is available at execution time: n8n
Executions list → find the failed execution → click "Retry" — resends the
original trigger data through the now-fixed workflow. Either path is a valid
demonstration of "retry after partial failure"; the script-based path needs
no browser.)

**Expected evidence of the successful retry**:
- New n8n execution, `status=success`, full chain green.
- Twenty: Order ORDER_6's Sync Status now `STATUS_SYNCED`; **exactly 1**
  Order Line Item now exists for it (created fresh, not duplicated); Person
  "Grace Editor" and Product SRV-PROOF are still **exactly 1 record each**
  (the retry re-ran the whole chain from the trigger, so Person/Product/Order
  upserts all matched existing records instead of creating new ones — zero
  duplicates anywhere, not just on the line items that were actually
  missing).

**Capture**: before/after GraphQL snapshots of Order ORDER_6 (Sync Status
field) and its Order Line Items count; n8n execution list showing one error
execution followed by one success execution for the same order.

---

## Scenario 7 — Both Twenty automations running — [x] EXECUTED 2026-07-22, see demo-results.md

**Precondition check (run this first, every time)** — before touching any
data, confirm category 6 actually reports done, then re-verify it
independently rather than trusting the report (project rule: unverified work
is not done):
```bash
docker compose exec twenty-db psql -U twenty -d default -c \
  'SELECT id, name, statuses FROM "workspace_7f0jbxrjrg6abdx9w68djxduf".workflow ORDER BY name;'
```
Expect 4 rows now (the 3 pre-existing built-ins/"Test lead" plus a new
"Order Synced Notification" row), and "Test lead"'s `statuses` should read
`{ACTIVE}` (not `{DRAFT,ACTIVE}` — a lingering unpublished draft is a sign the
fix was edited but not saved/activated, exactly the failure mode category 6
hit twice before).

### 7a. ARR (Opportunity)

**Fixture**: reuse the existing test Opportunity that category 6 has already
been using for every functional test of this workflow —
`8e9d9e20-e060-4086-8461-694fb2c5b0e6` ("Test oportunity"). Verified live
this session (read-only) via the helper script — current baseline:
```json
{"data":{"opportunities":{"edges":[{"node":{"id":"8e9d9e20-e060-4086-8461-694fb2c5b0e6","name":"Test oportunity","amount":{"amountMicros":0,"currencyCode":"USD"},"arr":{"amountMicros":0,"currencyCode":null}}}]}}}
```
(Not a fresh Opportunity, deliberately — reusing this fixture removes any
guesswork about `createOpportunity`'s required fields, and it's already at a
known, clean `amount: 0` baseline from category 6's own housekeeping.)

**Step 1 — baseline capture** (should match the JSON above; re-run anyway,
don't assume nothing changed since this was written):
```bash
./scripts/demo-twenty-graphql.sh 'query { opportunities(filter: {id: {eq: "8e9d9e20-e060-4086-8461-694fb2c5b0e6"}}) { edges { node { id name amount { amountMicros currencyCode } arr { amountMicros currencyCode } } } } }'
```

**Step 2 — trigger**: set Amount to a distinctive, easy-to-eyeball value —
$10,000 (`amountMicros: 10000000000`). Expected ARR = Amount × 12 = $120,000
(`amountMicros: 120000000000`).
```bash
./scripts/demo-twenty-graphql.sh 'mutation { updateOpportunity(data: { amount: { amountMicros: 10000000000, currencyCode: "USD" } }, id: "8e9d9e20-e060-4086-8461-694fb2c5b0e6") { id amount { amountMicros currencyCode } arr { amountMicros currencyCode } } }'
```
Note: this mutation's own immediate response will still show the OLD `arr`
(the workflow runs asynchronously, on a **1-minute cron enqueue** — don't
mistake the mutation's echo for the workflow's result).

**Step 3 — wait for the async run, then poll** (verified this session: the
workflow engine enqueues via `WorkflowRunEnqueueCronJob`, which ticks every
60s — a short sleep can miss it, use a real poll loop):
```bash
for i in 1 2 3 4; do
  sleep 20
  docker compose exec twenty-db psql -U twenty -d default -c \
    'SELECT r.id, r.status, r."createdAt" FROM "workspace_7f0jbxrjrg6abdx9w68djxduf"."workflowRun" r JOIN "workspace_7f0jbxrjrg6abdx9w68djxduf".workflow w ON w.id = r."workflowId" WHERE w.name = '"'"'Test lead'"'"' ORDER BY r."createdAt" DESC LIMIT 3;'
done
```
Stop as soon as a new row appears with `createdAt` after step 2's mutation.

**Step 4 — the actual proof, re-query the Opportunity**:
```bash
./scripts/demo-twenty-graphql.sh 'query { opportunities(filter: {id: {eq: "8e9d9e20-e060-4086-8461-694fb2c5b0e6"}}) { edges { node { id amount { amountMicros currencyCode } arr { amountMicros currencyCode } } } } }'
```
**Expected**: `arr.amountMicros = 120000000000`, `arr.currencyCode = "USD"`
(not null, not equal to `amount.amountMicros` — those are the two exact bugs
category 6 found and fixed).

**Step 5 — anti-loop proof**: exactly **one new** `workflowRun` row should
exist for "Test lead" with `status = SUCCESS` since step 2's edit (re-run the
same query as step 3). If step 4's Update Record write (which only touches
`arr`) had re-triggered the workflow, there would be a second new row
immediately after the first with no corresponding Amount edit — there must
not be one. Wait another ~40s and re-query once more to be sure nothing
delayed fires a second run.

**Step 6 — cleanup** (matches category 6's own established housekeeping —
leave the fixture at its known baseline for the next person who needs it):
```bash
./scripts/demo-twenty-graphql.sh 'mutation { updateOpportunity(data: { amount: { amountMicros: 0, currencyCode: "USD" } }, id: "8e9d9e20-e060-4086-8461-694fb2c5b0e6") { id amount { amountMicros currencyCode } arr { amountMicros currencyCode } } }'
```
This will legitimately fire a second, correct run (Amount genuinely changed
again) — expect `arr` to revert to `0` and one more new `SUCCESS` row. That's
correct behavior, not a loop — don't confuse it with Step 5's check, which is
about the *first* edit only producing one run.

**Capture**: the 4 JSON snapshots above (before/after amount+arr, both
`workflowRun` polls); screenshot of Twenty's own Settings → Workflows →
"Test lead" → Runs list if a browser is available at execution time (shows
the same run count/status with a nicer UI, not required if the DB query
evidence above is captured).

---

### 7b. Order-synced email

**Fixture**: a brand-new dedicated order (not a reused one — for a clean,
unambiguous single-row email table and an isolated Mailhog inbox count),
customer "Nora Publisher", 1x Manuscript Proofreading. This also happens to
be the strongest version of this proof: it runs the **entire** pipeline
(WooCommerce → n8n sync chain → Twenty Sync Status flips → Twenty's own
workflow fires → email lands), not just the Twenty-only half.

**Step 0 — clear Mailhog's inbox** so "exactly 1 email" is unambiguous:
```bash
curl -s -X DELETE https://$(grep ^DOMAIN_MAIL .env | cut -d= -f2)/api/v1/messages
curl -s https://$(grep ^DOMAIN_MAIL .env | cut -d= -f2)/api/v2/messages | python3 -c "import json,sys;print(json.load(sys.stdin)['total'])"
# ^ should print 0
```

**Step 1 — create and complete the order** (identical pattern to scenarios
1-6):
```bash
WP wc shop_order create --user=1 --status=processing --customer_id=0 \
  --billing='{"first_name":"Nora","last_name":"Publisher","email":"nora.publisher@example.com"}' \
  --line_items='[{"product_id":13,"quantity":1}]'
# note returned order id => ORDER_7
WP wc shop_order update ORDER_7 --status=completed --user=1
```

**Step 2 — n8n evidence** (the real sync chain ran, ending in Set Sync
Status Synced):
```bash
docker compose exec n8n-db psql -U n8n -d n8n -c \
  'SELECT id, status, "workflowId", "startedAt", "stoppedAt" FROM execution_entity ORDER BY id DESC LIMIT 3;'
```
Expect the newest row `status=success` against `OIOadgyS7EXEwyIU` (the
production workflow).

**Step 3 — Twenty evidence, Order synced**:
```bash
./scripts/demo-twenty-graphql.sh 'query { orders(filter: {wooOrderNumber: {eq: "ORDER_7"}}) { edges { node { id wooOrderNumber syncStatus customer{name{firstName lastName} emails{primaryEmail}} lineItems{edges{node{name quantity unitPrice{amountMicros} lineTotal{amountMicros}}}} } } } }'
```
(Replace `ORDER_7` with the real order id from Step 1.) Expect
`syncStatus: "STATUS_SYNCED"`, 1 line item, "Manuscript Proofreading".

**Step 4 — wait for the email workflow's async run** (same 1-minute cron
caveat as 7a):
```bash
for i in 1 2 3 4; do
  sleep 20
  docker compose exec twenty-db psql -U twenty -d default -c \
    'SELECT r.id, r.status, r."createdAt" FROM "workspace_7f0jbxrjrg6abdx9w68djxduf"."workflowRun" r JOIN "workspace_7f0jbxrjrg6abdx9w68djxduf".workflow w ON w.id = r."workflowId" WHERE w.name = '"'"'Order Synced Notification'"'"' ORDER BY r."createdAt" DESC LIMIT 3;'
done
```
Expect exactly 1 new row, `status = SUCCESS` (or check its `stepLogs`/`state`
column for the Send Email step's own log if status shows a partial failure —
worth inspecting either way since this step depends on the mailbox
connection working under real workflow conditions, not just the nodemailer
test category 6 already ran manually).

**Step 5 — the email itself** (no browser needed — Mailhog's REST API is
reachable the same way its web UI is, through Caddy):
```bash
curl -s https://$(grep ^DOMAIN_MAIL .env | cut -d= -f2)/api/v2/messages | python3 -m json.tool
```
Expect `"total": 1`; inspect that one message's `Content.Headers.Subject` (should
read like `Order #ORDER_7 synced (Nora Publisher)`) and `Content.Body` (should
be the HTML table with product "Manuscript Proofreading", qty 1, unit price
and line total matching Step 3's `unitPrice`/`lineTotal` in dollars, and the
correct order number/customer name/email per the JS template in
`PROGRESS.md`'s category 6 notes, Section B).

**Step 6 (optional, time-permitting) — screenshot for the demo**: open
`https://mail.63-181-247-69.sslip.io` in a browser and screenshot the email
next to Twenty's Settings → Workflows → "Order Synced Notification" → Runs
list — nicer visual evidence than raw JSON, not required if Steps 2-5's
captured output is sufficient.

**Note on the "doesn't double-send" property**: category 5's `Already
Synced?` guard means a real order's Sync Status only ever transitions
`Pending → Synced` once in practice (proven already in Scenario 5 — replayed
webhooks are no-ops against an already-synced order), so this workflow
firing exactly once per order is a direct, already-verified consequence of
category 5's dedup design, not something that needs a separate duplicate-
delivery test here. If there's spare time, an optional bonus check: manually
toggle a synced order back and forth
(`updateOrder(data: {syncStatus: STATUS_PENDING}, id: "...")` then back to
`STATUS_SYNCED`) and confirm the email workflow fires again each time a
transition into `Synced` genuinely happens — this is expected, correct
behavior (the trigger is scoped to the Sync Status field transitioning, not
"only once ever"), not a bug, and is not required core evidence.

---

## Post-demo notes
- Scenarios 1-6 are fully executable via WP-CLI + curl scripts, no browser
  required — all evidence is verifiable via GraphQL queries run through
  `docker compose exec`.
- Scenario 7b (email content) turns out to have an API-only path after all:
  Mailhog's REST API (`/api/v2/messages`) is reachable through Caddy the same
  as its web UI, so subject/body can be checked with `curl` + `python3 -m
  json.tool` — a browser is nice-to-have for a screenshot, not required to
  prove correctness.
- If time allows, re-run `demo-replay-webhook.sh` against one more scenario's
  order (e.g. ORDER_1) as a second, independent duplicate-delivery proof
  using a different order shape (single line item vs. Scenario 5's single
  add-on) — optional, not required.
