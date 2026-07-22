# Spines — WooCommerce → Twenty CRM Integration

An engineering project for Spines. When a WooCommerce order reaches
**Completed**, a webhook fires to a self-hosted **n8n** workflow, which syncs the
customer, order, products, quantities, prices, variations, and add-ons into a
self-hosted **Twenty CRM** — with duplicate-safe upserts and retry handling.

> **Status note:** every functional part of this build is now finished and
> verified end-to-end — infrastructure, shop data, Twenty data model, webhook
> gate, sync chain, both Twenty automations, and all 7 required demo
> scenarios. Sections below are marked `[STABLE]` throughout. See
> `PROGRESS.md` for the full session-by-session verification trail behind
> each claim.

---

## 1. Architecture `[STABLE]`

```
                        HTTPS (auto, Let's Encrypt via Caddy)
                                    │
                    ┌───────────────┴───────────────┐
                    │            Caddy               │  ← only public container
                    │  (reverse proxy, terminates TLS)│
                    └───┬───────────┬───────────┬─────┘
                        │           │           │
              shop.*.sslip.io  n8n.*.sslip.io  crm.*.sslip.io
                        │           │           │
                 ┌──────▼───┐  ┌────▼────┐  ┌────▼─────────┐
                 │WordPress │  │  n8n    │  │Twenty-server │
                 │+WooComm. │  │(workflow│  │(GraphQL/REST)│
                 └────┬─────┘  │ engine) │  └──────┬───────┘
                      │        └────┬────┘         │
                ┌─────▼─────┐  ┌────▼────┐   ┌──────▼──────┬────────────┐
                │wordpress- │  │ n8n-db  │   │  twenty-db  │Twenty-worker│
                │db (MariaDB│  │(Postgres│   │  (Postgres  │  + Redis    │
                │   11)     │  │   16)   │   │     16)     │             │
                └───────────┘  └─────────┘   └─────────────┘
```

All services run as Docker Compose services on a single Ubuntu 24.04 EC2 host
(t3.medium, eu-central-1), addressed by an Elastic IP. **Caddy is the only
container with published host ports** (80/443) — every other service is reached
only over the internal `spines_default` Docker network, including both
Postgres databases and the WordPress MariaDB database, which are never exposed
to the internet.

Public HTTPS hostnames are provided by [sslip.io](https://sslip.io) wildcard
DNS against the box's Elastic IP (`n8n.<ip-with-dashes>.sslip.io`, etc.), so no
purchased domain is required and Caddy can still obtain real Let's Encrypt
certificates automatically (see `Caddyfile`).

SSH (port 22) is restricted to the owner's IPv4 `/32` in the security group;
everything else inbound is closed except 80/443.

**Compose file layout:**
- `docker-compose.yml` — the core stack: caddy, n8n + n8n-db, twenty-server +
  twenty-worker + twenty-db + redis, plus a `mailhog` service (disposable
  SMTP catcher, no real mail delivery — see note below).
- `docker-compose.override.yml` — the test-shop stack (wordpress + wordpress-db),
  layered on automatically by `docker compose` when both files are present in
  the same directory. Kept separate because it's "test data infrastructure,"
  not part of the core integration path — a real deployment would point
  `DOMAIN_WP` at an already-hosted WooCommerce store instead.
- `Caddyfile` — one reverse-proxy block per hostname, env-driven via
  `{$DOMAIN_*}`.
- `postgres-init/` — first-boot bootstrap SQL for the two Postgres containers
  (see §3).

**Mailhog** (`mailhog/mailhog:latest`, proxied at `DOMAIN_MAIL`) is a
disposable, non-delivering SMTP catcher, connected in Twenty as a plain
IMAP/SMTP account (Settings → Accounts) purely so the completed-order email
automation (category 6, see `PROGRESS.md`) has a real mailbox to send
through and a web UI to visually confirm a send. Nothing sent through it
ever leaves the Docker network. Getting this working also required disabling
Twenty's outbound-SSRF guard for private IPs
(`OUTBOUND_HTTP_SAFE_MODE_ENABLED=false` on `twenty-server`/`twenty-worker`) —
safe here since there is no real external SMTP relay in this stack, but not a
setting to carry into a deployment with genuine external mail credentials —
and setting `LOGIC_FUNCTION_TYPE=LOCAL` on both, without which Twenty refuses
to run *any* workflow Code step at all (defaults to disabled outside
`NODE_ENV=development`). Both are commented in `docker-compose.yml` at their
point of use.

## 2. Data flow `[STABLE — built and verified]`

```
WooCommerce order → status = Completed
        │
        ▼
  WooCommerce webhook (topic: order.updated, HMAC secret = WC_WEBHOOK_SECRET)
        │  POST /woocommerce-orders   (path is lowercase — n8n webhook paths
        │                              are case-sensitive; see §9)
        ▼
  n8n: Webhook  (raw body capture)
        ▼
  n8n: Code "Verify Signature"
        │   HMAC-SHA256(raw body, WC_WEBHOOK_SECRET), timing-safe compare
        │   against x-wc-webhook-signature header. Short-circuits
        │   WooCommerce's connectivity "ping" payload (webhook_id=..., no
        │   real signature) as a clean success without further processing.
        ▼
  n8n: IF "Only Completed"  (status == "completed")
        │  false → stop (no-op, no Twenty writes)
        ▼ true
  n8n: Code "Upsert Person"       — find/create by email (lowercased)
        ▼
  n8n: Code "Upsert Products"     — find/create by SKU; updates Current
        │                            Price if found (Product is a live
        │                            record — see §4 for why that's safe)
        ▼
  n8n: Code "Upsert Order"        — find/create by Woo Order Number; reads
        │                            current Sync Status
        ▼
  n8n: IF "Already Synced?"
        │  true  → "Skip - Already Synced" (NoOp, dead end — this is the
        │           duplicate-webhook-delivery guard, see §6)
        ▼ false
  n8n: Code "Create Line Items"   — per Woo line item: name/price/variation
        │                            SNAPSHOT as sold; skips if a line item
        │                            for this exact (order, product,
        │                            variation) already exists (finer-
        │                            grained retry guard, see §6/§9)
        ▼
  n8n: Code "Set Sync Status Synced"  — updateOrder(syncStatus:
                                          STATUS_SYNCED), deliberately the
                                          last step — idempotent resume
                                          marker (see §4, §6)
```

The exported, working workflow lives at [`n8n/workflow.json`](./n8n/workflow.json)
("WooCommerce Order Sync", 10 nodes) — see §7 for how to import it.

**Verification performed** (all against live systems, re-queried via the
Twenty API afterward, not just "the node ran green"): an isolated unit test of
the Person upsert; a full synthetic order run through every step; a duplicate
delivery of the identical payload (confirmed zero new records, short-circuited
at "Already Synced?"); a simulated mid-chain crash followed by a retry
(confirmed the retry resumed cleanly with no duplicate line items); and three
real production orders (30/31/32) flipped to Completed through the actual
WooCommerce webhook, covering a new guest customer, a returning registered
customer, and a multi-product order with a variation and a paid add-on. Full
test log in `PROGRESS.md`'s category 5 session notes.

**Implementation note worth flagging for anyone extending this workflow:**
n8n's Code nodes run in an external JS Task Runner process where plain
`fetch()` is not available — every Twenty API call in this workflow instead
uses n8n's own `this.helpers.httpRequest(...)` helper. Also, Twenty's GraphQL
mutations take their input under the argument name `data`, not `input`.

## 3. Postgres init scripts `[STABLE]`

`n8n-db` and `twenty-db` are both plain `postgres:16` containers. The official
Postgres image already creates the role/database named by `POSTGRES_USER` /
`POSTGRES_PASSWORD` / `POSTGRES_DB` on first boot — that part needs no script.

`postgres-init/n8n-db/01-init.sql` and `postgres-init/twenty-db/01-init.sql`
are mounted read-only at `/docker-entrypoint-initdb.d/` in `docker-compose.yml`
and add a small set of extensions (`pg_trgm`, `uuid-ossp`, `btree_gin`) that
are commonly useful/expected alongside these apps. They deliberately **do not**
create any application schema — n8n and Twenty both own and migrate their own
schemas internally at startup. Per standard Postgres entrypoint behavior,
these scripts only run automatically the *first* time a container starts
against an empty data volume; they will not retroactively run against the
already-initialized volumes on the live server (documented here so it's not a
surprise) — they matter for anyone standing the stack up fresh from this repo.

## 4. CRM data model (in Twenty) `[STABLE]`

Built in Twenty as custom objects + fields (Person is Twenty's built-in
object) via Twenty's own metadata API — not via hand-authored SQL, since
Twenty owns and migrates its own Postgres schema internally. (Partway through
the build these custom objects were briefly found *missing*, despite an
earlier status-board entry claiming they were done — root-caused via direct
Postgres inspection and rebuilt with a full live create/relate/reject-
duplicate/delete round trip; see `PROGRESS.md` and `PROJECT_SUMMARY.md` for
the full incident writeup.)

| Object | Type | Unique key | Fields | Relations |
|---|---|---|---|---|
| **Person** | built-in | email, lowercased | (Twenty defaults) | ← Order.Customer |
| **Product** | custom | SKU | SKU, Current Price, Description | ← Order Line Item.Product |
| **Order** | custom | Woo Order Number | Total, Order Date, Sync Status (`STATUS_PENDING` / `STATUS_SYNCED`; shown as "Pending"/"Synced" in the UI) | Customer → Person |
| **Order Line Item** | custom | (Order, Product, Variation) composite in practice | Quantity, Unit Price, Line Total, Variation, Name (snapshot) | Order →, Product → |

**A concrete naming constraint worth knowing:** Twenty validates SELECT field
option values against a two-segment pattern (`^[A-Z0-9]+_[A-Z0-9]+$`) — a bare
`PENDING` is rejected. That's why Sync Status stores `STATUS_PENDING` /
`STATUS_SYNCED` under the hood while the human-facing labels stay exactly
"Pending"/"Synced." Anything writing to this field — the n8n sync chain, a
Twenty automation's trigger filter — has to use the real enum literal, not
the label.

**Why this shape:**
- **Person matched by lowercased email** — the one identifier guaranteed
  present for both a registered WooCommerce customer account *and* a guest
  checkout (billing email only). Handles "returning customer" correctly
  whether or not they ever created an account.
- **Product matched by SKU**, not by internal Woo product ID alone — SKU is
  the stable human/business identifier Spines already assigns, and it's what
  uniquely identifies a *variation* too (e.g. `PKG-SIG` vs `PKG-ESS`), so
  variations upsert as their own Product-like line-item references without
  extra modeling.
- **Order Line Item's Name field is a snapshot** of the product name *as sold*,
  taken at sync time — not a live lookup through the Product relation. If a
  product is later renamed or repriced, historical orders must keep showing
  what the customer actually bought and paid. Only the Line Item's own
  Unit Price / Line Total / Name are historical truth; the related Product
  record's Current Price is allowed to drift forward.
- **Sync Status flips to `Synced` as the literal last write in the chain.**
  This is what makes partial-failure retries safe (see §6) and is also the
  resume marker + what the completed-order email automation (category 6)
  triggers on.

## 5. Twenty automations (ARR + completed-order email) `[STABLE — built and verified]`

Two automations live entirely **inside Twenty** (its own workflow-builder
feature, not n8n) and are only authorable via Twenty's UI — no metadata API
covers step-level wiring (input variables, step-output references), confirmed
by calling the real workflow-builder mutations directly rather than assuming.
They are not separately exportable as a file the way the n8n workflow is;
this section plus `PROGRESS.md`'s category 6 notes are the record of what was
built and how it was verified.

**A — ARR on Opportunity.** Trigger: Opportunity `amount` updated. Step: a
Code (JS) action computing `arr = amount × 12`, then an Update Record step
writing it back to the same Opportunity's `arr` field. Handles empty/zero
`amount` (resolves to `arr = 0`, not an error). Verified it does **not**
re-trigger itself: the workflow's own write to `arr` does not re-fire the
`amount`-updated trigger, confirmed by polling `workflowRun` across several
minutes around a real edit and seeing exactly one run per genuine `amount`
change, not a cascade. Live test: Opportunity `amount` set to $10,000 →
re-queried `arr = $120,000` exactly.

**B — Order-synced email.** Trigger: `Order.syncStatus` transitions to
`STATUS_SYNCED` (a `DATABASE_EVENT` trigger on `order.upserted`, filtered on
that field — this is the same "flip Sync Status last" resume marker
described in §2/§4, doing double duty as this automation's trigger). Steps:
find the related Person (`Customer`) → find the order's Line Items → build an
email subject/body summarizing the order (product names, quantities, prices,
total) → send via a connected mailbox (Mailhog in this stack, see §1). Live
test: a real order synced end-to-end through the full pipeline
(WooCommerce → n8n → Twenty) produced exactly 1 email, correctly addressed
and personalized, matching the order's real data.

**Two known operational wrinkles, disclosed honestly (neither is a pipeline
defect):**
- The completed-order email's **HTML MIME part is cosmetically
  double-escaped** — Mailhog's HTML view renders literal `&lt;h2&gt;` tag text
  instead of a heading. The **plain-text part is correct** and fully
  readable, and all data in both parts (customer, line items, total) is
  accurate. Root cause not chased further since the plain-text part already
  satisfies "the email fires with correct content"; flagged here rather than
  hidden.
- **WordPress's Action Scheduler queue (WP-Cron) is pseudo-cron**, not a real
  timer — it only runs due jobs when something hits the site, so a
  `completed`-order webhook can sit queued for longer than expected on a
  quiet site. Observed once during demo Scenario 7 and resolved with
  `wp cron event run action_scheduler_run_queue` (a legitimate "run what's
  due now" nudge, not a fabricated trigger). A production deployment behind
  real traffic, or an external cron hitting `wp-cron.php` on an interval,
  would not see this; a from-scratch/demo instance might.

## 6. Duplicate prevention + retry approach `[STABLE — built and verified]`

Core principle: **upsert-everything, keyed by a stable natural identifier,
nothing keyed by "did we already see this webhook."**

| Failure mode (from the assignment's required test scenarios) | How it's handled | Verified |
|---|---|---|
| Same webhook delivered twice (WooCommerce retries on any non-2xx, or manual re-delivery) | Every write is "look up by unique key, create only if missing." Re-running the whole chain against an already-synced order re-finds the same Person/Product/Order/Line-Item rows and writes nothing new — the "Already Synced?" IF short-circuits before Create Line Items even runs. | Yes — resent an identical payload; API confirmed record counts unchanged. |
| Retry after a partial failure (e.g. Person + Products upserted, then a crash before Order/Line-Items) | Every step is independently idempotent (upsert-by-key), so re-running the same or a fresh delivery picks up wherever it left off — already-created rows are found, not duplicated. `Sync Status` staying `Pending` is itself the signal that a retry is still owed. | Yes — a workflow forced to crash mid-chain, then re-run for real; API confirmed the order ended with exactly the right number of line items, not double. |
| Order already fully synced | The Order upsert step checks `Sync Status`; if already `Synced`, the "Already Synced?" IF skips straight to a dead-end NoOp — a duplicate delivery after full success is a fast no-op, not a re-processing. | Yes. |
| Returning customer | Person upsert by lowercased email finds the existing record instead of creating a second one — true for both guest and registered customers. | Yes — real order 31 (Alice, returning) resolved to the same Person id as order 30. |
| Same product across multiple orders | Product upsert by SKU finds the existing Product record; only a new Order Line Item (pointing at the existing Product) is created per order. | Yes — SRV-PROOF confirmed as a single reused Product row across two real orders. |
| Multi-product / variations / add-ons in one order | Each Woo line item (including variations and the add-on-as-separate-line-item) becomes its own Order Line Item row, all pointing at the same Order. | Yes — real order 30 (Signature package variation + Audiobook add-on) produced exactly 2 correctly-priced line items. |

A second, finer-grained guard sits underneath the order-level check: **Create
Line Items** looks up each line by the exact `(order, product, variation)`
triple before creating it, so even a crash *inside* line-item creation (some
lines written, others not) can be safely retried without double-creating the
lines that already exist.

This is deliberately **not** "record webhook delivery IDs and drop duplicates,"
because that approach doesn't help with partial-failure retries (a retry may
be a *different* delivery ID for logically the same state) and doesn't survive
someone manually re-sending a webhook from WooCommerce's admin UI. Keying
everything off natural business identifiers (email, SKU, Woo order number)
makes the whole chain safe to run any number of times against the same order.

Signature verification (HMAC-SHA256, timing-safe compare) additionally
ensures only genuine WooCommerce-originated requests reach the sync chain at
all — see §2.

## 7. Setup `[STABLE]`

1. Provision an Ubuntu server, open only 80/443/22 (22 restricted to your IP).
2. `git clone` this repo, `cp .env.example .env`, fill in real values (see
   comments in `.env.example` for how to generate each secret).
3. Point `DOMAIN_N8N` / `DOMAIN_TWENTY` / `DOMAIN_WP` (and, if you want the
   completed-order email automation demoable, `DOMAIN_MAIL`) at the server
   (sslip.io needs no DNS setup — see §1).
4. `docker compose up -d` — brings up the full stack; Caddy will obtain
   HTTPS certs automatically on first request to each hostname.
5. Complete first-run setup in Twenty (create the workspace, generate an API
   key in Settings → APIs & Webhooks for `TWENTY_API_KEY`), then build the
   custom objects/fields/relations from §4 — either by hand in
   Settings → Data model, or by replicating them via Twenty's
   `/rest/metadata/objects` + `/rest/metadata/fields` endpoints (see
   `PROGRESS.md`'s category 3 session notes for the exact request payloads
   this project used, including the `relationCreationPayload` shape and the
   two-segment SELECT-option requirement from §4).
6. Install WooCommerce on the WordPress site, configure the webhook (topic
   `order.updated`, secret = `WC_WEBHOOK_SECRET`, delivery URL
   `https://<DOMAIN_N8N>/webhook/woocommerce-orders` — note the path is
   lowercase; n8n webhook paths are case-sensitive).
7. Import the exported workflow into n8n:
   ```bash
   docker compose cp n8n/workflow.json n8n:/tmp/workflow.json
   docker compose exec n8n n8n import:workflow --input=/tmp/workflow.json --activeState=fromJson
   ```
   The export's `active` field is `true`, so `--activeState=fromJson` should
   activate it directly on import; if it doesn't (this can depend on n8n
   version/project assignment), open the workflow in the n8n UI and flip the
   Active toggle by hand. Confirm it's live by checking Executions after the
   next real webhook delivery.
8. Build the two Twenty automations from §5 by hand in Settings → Workflows
   (no API path exists for step-level wiring — see §5/§10 for why): the ARR
   Code+Update-Record pair on Opportunity `amount`, and the order-synced-email
   chain triggered on `Order.syncStatus → STATUS_SYNCED`. Connect a mailbox
   (Settings → Accounts) for the email step to send through — Mailhog is
   wired up in this stack for a real, non-delivering test mailbox with a web
   UI at `DOMAIN_MAIL`.
9. Run `scripts/seed-orders.sh <admin-username>` to create test
   customers/products/orders, or place orders manually through the
   WordPress/WooCommerce admin, then flip an order to **Completed** to
   trigger a real sync. See §8 for the full demonstration walkthrough.

## 8. Demonstration scenarios `[7 of 7 EXECUTED — see demo-results.md]`

The assignment requires demonstrating: new customer, returning customer,
multi-product + add-ons order, a previously-purchased product in a new order
(with historical price preserved), duplicate webhook delivery, a run that
fails partway then succeeds on retry, and both Twenty automations firing.

All 7 scenarios have been run for real against the live stack (real WP-CLI
orders, real n8n executions, real Twenty GraphQL reads as evidence — not a dry
run) and are fully documented, query-by-query, in
[`demo-results.md`](./demo-results.md); the runbook used to drive them is in
[`demo-script.md`](./demo-script.md). Summary:

| # | Scenario | Result |
|---|---|---|
| 1 | New customer | New guest (Emma Writer) → 1 new Person, 1 Order, 1 Line Item |
| 2 | Returning customer | Alice's 3rd order resolves to her existing Person id, not a new one |
| 3 | Multi-product + variation + add-on | 1 order, 3 correctly-priced Line Items in a single sync |
| 4 | Product reused + historical price preserved | Product's live price updated; two earlier orders' Line Item snapshots unchanged |
| 5 | Duplicate webhook delivery | Identical signed payload replayed 3×; exactly 1 Order / 1 Line Item resulted, not 3 |
| 6 | Fail partway, then retry | Simulated mid-chain crash (Person/Product/Order created, no Line Items) followed by a clean, non-duplicating retry through the real production workflow |
| 7 | Both Twenty automations fire | **Executed.** ARR: Opportunity `amount` → $10,000, re-queried `arr` = $120,000 exactly, plus a 3-poll anti-loop check confirming the workflow's own write-back doesn't re-trigger it. Email: fresh order 38 (Nora Publisher) run end-to-end through the real pipeline produced exactly 1 correctly-addressed, correctly-personalized email in Mailhog. See §5 for what these automations do and two disclosed operational wrinkles hit along the way. |

Scenarios 5 and 6 used two small helper scripts,
[`scripts/demo-replay-webhook.sh`](./scripts/demo-replay-webhook.sh) (replays a
real order's payload with a freshly-computed valid HMAC signature) and
[`scripts/demo-retrigger-webhook.sh`](./scripts/demo-retrigger-webhook.sh)
(forces a fresh natural `order.updated` webhook via a no-op order save) —
both read secrets from `.env` at runtime and never hardcode or print them.

## 9. Limitations & assumptions `[honest, current as of this build]`

- **Paid add-ons are modeled as separate line items**, not WooCommerce's
  native product add-ons — WooCommerce core has no built-in paid add-on
  concept; a real deployment would likely use a plugin (e.g. Product Add-Ons)
  and this integration would need to read its line-item metadata format
  instead. This is a deliberate, documented simplification for the test data,
  not an oversight.
- **No purchased domain / DNS** — sslip.io gives free HTTPS-capable hostnames
  tied to the server's IP. If the Elastic IP ever changes, every `DOMAIN_*`
  value and the WooCommerce webhook delivery URL must be updated together.
- **Single-host deployment** — no HA/failover for any component (Postgres,
  n8n, Twenty, WordPress). Acceptable for a demo build; would need
  managed/replicated databases and multiple app instances for production.
- **No outbound mail transport configured** in the stack, so WordPress's own
  transactional emails (e.g. "order updated" notification to the shop admin)
  fail silently with a connection-refused on `sendmail`. This does not affect
  the webhook → n8n → Twenty pipeline (which does not depend on WordPress
  mail), but it is a known gap if WooCommerce's own customer-facing emails
  were ever required.
- **Twenty's data model was created via Twenty's own metadata API**
  (`/rest/metadata/objects` + `/rest/metadata/fields`), not via a hand-rolled
  migration script and not by clicking through the UI — Twenty owns and
  migrates its own Postgres schema, so this project drove that schema through
  Twenty's own supported API surface instead of writing SQL against it
  directly. This means recreating the object model on a fresh Twenty instance
  is either a manual UI step or a scripted replay of those API calls (both
  documented, see §4/§7), not a single `docker compose up`.
- **Order Line Item's "unique key"** is described in §4 as a composite
  (Order, Product, Variation) rather than a single dedicated field, because
  Twenty's custom objects don't enforce composite-unique constraints at the
  database level the way a hand-rolled Postgres schema could — dedup safety
  for line items instead comes from the *Order*-level `Sync Status` gate (an
  order is only ever line-itemed once, since re-runs against an already-synced
  order skip line-item creation entirely, plus the finer-grained per-line-item
  existence check described in §6) rather than a database constraint. Worth
  knowing as a modeling trade-off, not a silent gap.
- **The line-item dedup key is (Order, Product, Variation) — not WooCommerce's
  own internal `line_item.id`.** This is correct for this catalog: WooCommerce
  never produces two separate line items for the same product + variation
  within one order here, so the composite key is a faithful match. It would
  misbehave for a hypothetical future catalog that legitimately needed two
  distinct line entries for the *same* product + variation in a single order
  (e.g. the same service booked twice for two different scheduled dates) — a
  real edge case this integration does not attempt to handle, disclosed here
  rather than silently assumed away.
- **The completed-order email's HTML MIME part is cosmetically
  double-escaped** (Mailhog's HTML view shows literal `&lt;h2&gt;` tag text
  instead of a rendered heading). The plain-text part is correct and fully
  readable, and all data in both parts is accurate — this is a rendering
  quirk in how the HTML string is built/sent, not a data or dedup problem,
  and was left as-is rather than chased further since the email's substance
  (subject, recipient, order content) is already fully correct. See §5.
- **WordPress's Action Scheduler queue (WP-Cron) is pseudo-cron**, not a real
  timer — a `completed`-order webhook can sit queued longer than expected on
  a quiet, low-traffic site until something happens to hit it (this test
  instance needed a manual `wp cron event run action_scheduler_run_queue`
  nudge once, during demo Scenario 7). Real traffic, or an external ticker
  hitting `wp-cron.php` on an interval, avoids this in a production
  deployment. See §5.

## 10. AI tools used

See [`AI_TOOLS.md`](./AI_TOOLS.md) for a specific, honest account of which AI
tooling was used for this project, what for, and how its output was verified
rather than trusted blindly.
