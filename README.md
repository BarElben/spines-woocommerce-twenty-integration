# Spines — WooCommerce → Twenty CRM Integration

Tech Lead hiring assignment for Spines. When a WooCommerce order reaches
**Completed**, a webhook fires to a self-hosted **n8n** workflow, which syncs the
customer, order, products, quantities, prices, variations, and add-ons into a
self-hosted **Twenty CRM** — with duplicate-safe upserts and retry handling.

> **Status note (this README is a living document):** sections below are marked
> `[STABLE]` where the design/implementation is finished and verified, or
> `[IN PROGRESS]` / `[PENDING]` where work is still ongoing in this repo's build.
> See `PROGRESS.md` for the current per-category percentage and verification
> notes. Do not treat `[PENDING]` sections as final.

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
  twenty-worker + twenty-db + redis.
- `docker-compose.override.yml` — the test-shop stack (wordpress + wordpress-db),
  layered on automatically by `docker compose` when both files are present in
  the same directory. Kept separate because it's "test data infrastructure,"
  not part of the core integration path — a real deployment would point
  `DOMAIN_WP` at an already-hosted WooCommerce store instead.
- `Caddyfile` — one reverse-proxy block per hostname, env-driven via
  `{$DOMAIN_*}`.
- `postgres-init/` — first-boot bootstrap SQL for the two Postgres containers
  (see §3).

## 2. Data flow `[STABLE design / IN PROGRESS build]`

```
WooCommerce order → status = Completed
        │
        ▼
  WooCommerce webhook (topic: order.updated, HMAC secret = WC_WEBHOOK_SECRET)
        │  POST /webhook/woocommerce-orders
        ▼
  n8n: Webhook node (raw body capture)
        │
        ▼
  n8n: Code node "Verify Signature"
        │   HMAC-SHA256(raw body, WC_WEBHOOK_SECRET), timing-safe compare
        │   against x-wc-webhook-signature header. Also short-circuits
        │   WooCommerce's connectivity "ping" payload (webhook_id=..., no
        │   real signature) as a clean success without further processing.
        ▼
  n8n: IF "Only Completed"  (status == "completed")
        │  false → stop (no-op, no Twenty writes)
        ▼ true
  [PENDING — category 5, not yet built in this workflow]
  upsert Person (by email, lowercased)
        → upsert Products (by SKU)
        → upsert Order (by Woo order number; skip remaining steps if
          Sync Status already = synced)
        → create Order Line Items (name/price/variation SNAPSHOT as sold)
        → set Order.Sync Status = synced   (last step — idempotent marker)
```

The webhook gate (Webhook → Verify Signature → Only-Completed IF) is built and
verified end-to-end against real WooCommerce traffic, including a rejected
forged-signature request and the WooCommerce ping payload. The sync chain
after the IF node (upserts into Twenty) is still being built — see
`PROGRESS.md` category 5 for current state. **The exported workflow JSON in
this repo will only be added once that chain is finished and verified**, so
that the artifact in the repo reflects working, tested behavior rather than a
partial workflow.

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

Built directly in Twenty via its UI (custom objects + fields), not via SQL —
Twenty owns and migrates its own Postgres schema.

| Object | Type | Unique key | Fields | Relations |
|---|---|---|---|---|
| **Person** | built-in | email, lowercased | (Twenty defaults) | ← Order.Customer |
| **Product** | custom | SKU | SKU, Current Price, Description | ← Order Line Item.Product |
| **Order** | custom | Woo Order Number | Total, Order Date, Sync Status (`pending`/`synced`) | Customer → Person |
| **Order Line Item** | custom | (Order, Product, Variation) composite in practice | Quantity, Unit Price, Line Total, Variation, Name (snapshot) | Order →, Product → |

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
- **Sync Status flips to `synced` as the literal last write in the chain.**
  This is what makes partial-failure retries safe (see §5) and is also the
  resume marker + what the completed-order email automation (category 6)
  triggers on.

## 5. Duplicate prevention + retry approach `[STABLE design]`

Core principle: **upsert-everything, keyed by a stable natural identifier,
nothing keyed by "did we already see this webhook."**

| Failure mode (from the assignment's required test scenarios) | How it's handled |
|---|---|
| Same webhook delivered twice (WooCommerce retries on any non-2xx, or manual re-delivery) | Every write is "look up by unique key, create only if missing." Re-running the whole chain against an already-synced order re-finds the same Person/Product/Order/Line-Item rows and writes nothing new. |
| Retry after a partial failure (e.g. Person + Products upserted, then a transient error before Order/Line-Items) | Because every step is independently idempotent (upsert-by-key), simply re-running the same execution (or a fresh delivery of the same webhook) picks up wherever it left off — already-created rows are found, not duplicated, and the remaining steps proceed. `Sync Status` staying `pending` is itself the signal that a retry is still needed. |
| Order already fully synced | The Order upsert step checks `Sync Status`; if already `synced`, the remaining line-item/email-triggering steps are skipped — so a duplicate delivery after full success is a fast no-op, not a re-processing. |
| Returning customer | Person upsert by lowercased email finds the existing record instead of creating a second one. |
| Same product across multiple orders | Product upsert by SKU finds the existing Product record; only a new Order Line Item (pointing at the existing Product) is created per order. |
| Multi-product / variations / add-ons in one order | Each Woo line item (including variations and the add-on-as-separate-line-item, see `CLAUDE.md`'s product design notes) becomes its own Order Line Item row, all pointing at the same Order. |

This is deliberately **not** "record webhook delivery IDs and drop duplicates,"
because that approach doesn't help with partial-failure retries (a retry may
be a *different* delivery ID for logically the same state) and doesn't survive
someone manually re-sending a webhook from WooCommerce's admin UI. Keying
everything off natural business identifiers (email, SKU, Woo order number)
makes the whole chain safe to run any number of times against the same order.

Signature verification (HMAC-SHA256, timing-safe compare) additionally
ensures only genuine WooCommerce-originated requests reach the sync chain at
all — see §2.

## 6. Setup `[PENDING — final steps depend on category 5 completion]`

High-level steps (will be filled in with exact commands once the sync chain
and workflow export are finalized):

1. Provision an Ubuntu server, open only 80/443/22 (22 restricted to your IP).
2. `git clone` this repo, `cp .env.example .env`, fill in real values (see
   comments in `.env.example` for how to generate each secret).
3. Point `DOMAIN_N8N` / `DOMAIN_TWENTY` / `DOMAIN_WP` at the server (sslip.io
   needs no DNS setup — see §1).
4. `docker compose up -d` — brings up the full stack; Caddy will obtain
   HTTPS certs automatically on first request to each hostname.
5. Complete first-run setup in the Twenty UI (create workspace, build the
   custom objects in §4, generate an API key for `TWENTY_API_KEY`).
6. Install WooCommerce on the WordPress site, configure the webhook
   (topic `order.updated`, secret = `WC_WEBHOOK_SECRET`, delivery URL
   `https://<DOMAIN_N8N>/webhook/woocommerce-orders`).
7. `[PENDING]` Import the exported n8n workflow (`n8n/workflow.json`, not yet
   added — see §2) and activate it.
8. `[PENDING]` Run `scripts/seed-orders.sh <admin-username>` to create test
   customers/products/orders, or place orders manually, then walk through the
   demo scenarios in `[PENDING — category 7]`.

## 7. Demonstration scenarios `[PENDING — category 7, not started]`

The assignment requires demonstrating: new customer, returning customer,
multi-product + add-ons order, a previously-purchased product in a new order,
duplicate webhook delivery, a run that fails partway then succeeds on retry,
and both Twenty automations firing. None of these have been recorded yet —
this section will be replaced with the actual walkthrough (commands + expected
Twenty state + screenshots/log excerpts) once categories 5–6 are done.

## 8. Limitations & assumptions `[honest, current as of this build]`

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
  n8n, Twenty, WordPress). Acceptable for a hiring-assignment demo; would need
  managed/replicated databases and multiple app instances for production.
- **No outbound mail transport configured** in the stack, so WordPress's own
  transactional emails (e.g. "order updated" notification to the shop admin)
  fail silently with a connection-refused on `sendmail`. This does not affect
  the webhook → n8n → Twenty pipeline (which does not depend on WordPress
  mail), but it is a known gap if WooCommerce's own customer-facing emails
  were ever required.
- **Twenty's data model was built by hand via the UI**, not via a migration
  script, per the assignment's allowance to design/document the model rather
  than mandate infrastructure-as-code for Twenty's own schema. This means
  recreating the object model on a fresh Twenty instance is a manual (but
  documented, see §4) step, not a single command.
- **Order Line Item's "unique key"** is described in §4 as a composite
  (Order, Product, Variation) rather than a single dedicated field, because
  Twenty's custom objects don't enforce composite-unique constraints at the
  database level the way a hand-rolled Postgres schema could — dedup safety
  for line items instead comes from the *Order*-level `Sync Status` gate (an
  order is only ever line-itemed once, since re-runs against an already-synced
  order skip line-item creation entirely; see §5). Worth knowing as a modeling
  trade-off, not a silent gap.
- **This README will keep changing** until categories 5–7 are complete — the
  `[PENDING]` tags above are intentionally visible rather than pre-writing
  content for work that hasn't happened yet.

## 9. AI tools used

See [`AI_TOOLS.md`](./AI_TOOLS.md) for a specific, honest account of which AI
tooling was used for this project, what for, and how its output was verified
rather than trusted blindly.
