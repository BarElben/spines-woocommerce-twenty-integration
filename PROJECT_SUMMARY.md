# WooCommerce → Twenty CRM Integration — Engineering Summary

*Snapshot: 2026-07-22. Weighted completion: **99.8%** — every functional
category (infrastructure, shop data, Twenty data model, webhook gate, sync
chain, both Twenty automations, and all 7 required demonstration scenarios)
is built and independently verified end-to-end. The only remaining 0.2% is
the owner's own final review/commit/submission step. See `PROGRESS.md` for
the full session-by-session verification trail and `README.md` for complete
setup/architecture detail.*

A self-hosted pipeline that syncs completed WooCommerce orders — customers,
products, quantities, prices, variations, and add-ons — into Twenty CRM, with
dedup-safe upserts and retry handling designed to survive duplicate webhook
deliveries and partial failures.

---

## 1. Architecture

One EC2 host, one Docker Compose stack, one public entry point.

Every service runs as a Docker Compose container on a single Ubuntu 24.04 EC2
instance (t3.medium, eu-central-1) behind a fixed Elastic IP. **Caddy is the
only container with a published host port** — it terminates HTTPS
automatically (Let's Encrypt) and reverse-proxies to the shop, the workflow
engine, and the CRM by hostname. Every database sits on the internal Docker
network only, never reachable from the internet.

```mermaid
flowchart LR
    WC["WooCommerce shop<br/>(order → Completed)"] -- "HMAC-signed<br/>webhook" --> Caddy

    subgraph Host["Single EC2 host — Docker Compose"]
        Caddy["Caddy<br/>reverse proxy · auto-HTTPS"]
        Caddy --> WP["WordPress"]
        Caddy --> N8N["n8n<br/>workflow engine"]
        Caddy --> Twenty["Twenty CRM<br/>server + worker"]

        WP --> WPDB[("wordpress-db<br/>MariaDB 11")]
        N8N --> N8NDB[("n8n-db<br/>Postgres 16")]
        Twenty --> TwentyDB[("twenty-db<br/>Postgres 16")]
        Twenty --> Redis[("redis")]

        N8N -. "GraphQL / REST<br/>upserts" .-> Twenty
    end
```

No purchased domain is required: `n8n.<elastic-ip>.sslip.io`,
`crm.<elastic-ip>.sslip.io`, and `shop.<elastic-ip>.sslip.io` resolve straight
back to the box via sslip.io's wildcard DNS, which is enough for Caddy to
obtain real certificates. SSH is restricted to the owner's own IPv4 `/32`;
only 80 and 443 are otherwise open. All persistent state lives in named
Docker volumes, so a container restart or redeploy doesn't lose data.

The compose files are deliberately split in two: `docker-compose.yml` is the
core integration stack (Caddy, n8n + n8n-db, Twenty server + worker +
twenty-db + redis); `docker-compose.override.yml` layers on the WordPress
test shop, kept separate because a real deployment would point at an
already-hosted WooCommerce store instead of standing up its own.

---

## 2. CRM data model

Four objects in Twenty, each with a natural, stable identifier — chosen so
upserts are safe to run any number of times.

| Object | Unique key | Fields | Relations |
|---|---|---|---|
| **Person** *(built-in)* | Email, lowercased | Name, email | ← Order.Customer |
| **Product** | `SKU` | SKU, Current Price, Description | ← Order Line Item.Product |
| **Order** | `Woo Order Number` | Total, Order Date, Sync Status (`STATUS_PENDING`/`STATUS_SYNCED`) | Customer → Person; ← Order Line Item.Order |
| **Order Line Item** | Order + Product + Variation | Quantity, Unit Price, Line Total, Variation, Name *(snapshot)* | Order →, Product → |

**Why these keys:**
- **Email, lowercased,** is the one identifier guaranteed present whether the
  customer registered an account or checked out as a guest — a returning
  guest and a returning registered customer both resolve to the same Person.
- **SKU** is the business identifier already assigned by the business, specific enough
  to distinguish variations directly (`PKG-ESS` vs. `PKG-SIG` vs. `PKG-PAR`)
  without extra modeling.
- **Order Line Item's Name field is a point-in-time snapshot** of the product
  name as sold, written at sync time — not a live lookup through the Product
  relation. A later rename or price change on the Product must never rewrite
  what a past order shows the customer actually bought and paid.

**Naming detail worth knowing:** Twenty validates SELECT field option values
against a two-segment pattern (`^[A-Z0-9]+_[A-Z0-9]+$`) — a bare `PENDING` is
rejected. Sync Status therefore stores `STATUS_PENDING`/`STATUS_SYNCED` under
the hood, while the human-facing labels stay "Pending"/"Synced." Anything
writing to this field has to use the real enum literal, not the label.

---

## 3. Sync & automation

The webhook gate, the upsert chain, and both Twenty-side automations are
all built and independently verified against live traffic and real
functional tests — not just "the workflow ran green."

### Webhook gate — built, verified against live WooCommerce traffic

1. **Webhook node** receives the WooCommerce `order.updated` delivery with
   raw-body capture enabled.
2. **Verify Signature** (Code node) computes HMAC-SHA256 over the raw body
   with the shared webhook secret and compares it to the
   `x-wc-webhook-signature` header using a timing-safe comparison.
   WooCommerce's own connectivity ping (`webhook_id=…`, no real signature) is
   recognized and short-circuited to a clean success without reaching
   further logic.
3. **"Only Completed" gate** (IF node) checks `status == "completed"`. Any
   other status exits with zero writes to Twenty.

This gate has been exercised against real WooCommerce deliveries, not
synthetic payloads: real orders were flipped through non-completed and
completed statuses and traced end-to-end in n8n's own execution log, and a
deliberately forged signature was sent directly at the endpoint to confirm it
is actually rejected rather than passed through.

### Upsert chain into Twenty — built and verified end-to-end

```mermaid
flowchart LR
    A["Upsert Person<br/>by email"] --> B["Upsert Products<br/>by SKU"]
    B --> C["Upsert Order<br/>by Woo Order Number<br/>(skip rest if already Synced)"]
    C --> D["Create Order Line Items<br/>name / price / variation snapshot"]
    D --> E["Set Sync Status = Synced<br/>(last step — idempotent marker)"]
```

Every step is a lookup-by-natural-key, create-only-if-missing operation —
never an unconditional insert. The Sync Status flip happens last and only
after every line item exists, which is what makes it both a safe resume
marker for retries and a clean trigger for the completed-order email
automation. Verified against real production orders (new guest customer,
returning registered customer, multi-product order with a variation and a
paid add-on), a duplicate webhook replay (zero extra records), and a
deliberately crashed mid-chain run followed by a clean retry.

### Twenty automation — ARR on Opportunity ✅ verified working

A Code step recomputes `ARR = Amount × 12` whenever an Opportunity's Amount
is created or changed, safely coercing empty/zero amounts to `0` rather than
erroring. The automation's trigger is restricted to fire only on changes to
the **Amount** field; the subsequent Update Record step only ever writes the
**ARR** field. Because that write's changed-field set never includes Amount,
it can never re-match the trigger — the loop-guard is structural, not a flag
or counter. Live-tested twice: Amount set to $10,000 → ARR recomputed to
exactly $120,000, with a multi-poll check confirming the workflow's own
write-back never re-triggers itself.

### Twenty automation — completed-order email ✅ verified working

Triggers on Order.Sync Status transitioning to Synced (restricted to that
one field, so it fires exactly once per order's real lifetime), looks up the
order's Customer and Line Items, and a Code step formats an HTML/plain-text
summary — customer, order date, a product/variation/qty/price table, and the
order total — for a Send Email step to route to a connected mailbox. Live
end-to-end test: a brand-new order run through the real WooCommerce → n8n →
Twenty pipeline produced exactly one correctly-addressed, correctly-
personalized email (subject `Order #38 synced (Nora Publisher)`, to the
real customer's address, with accurate line items and total). One disclosed
cosmetic defect: the email's HTML part is double-escaped in the test
mailbox's HTML view (the plain-text part renders correctly and all data in
both parts is accurate) — flagged rather than hidden, see Limitations.

---

## 4. Dedup & retry approach

One rule covers every required scenario: upsert by natural key, never by
"have we seen this webhook before."

Deliveries aren't deduplicated by tracking webhook or delivery IDs — that
approach breaks the moment a retry arrives under a different delivery ID for
the same logical order, or someone manually re-sends a webhook from the
WooCommerce admin. Instead, every write in the chain looks up a stable
business key first and only creates a record if nothing matches it.

| Scenario | Why it produces zero duplicates |
|---|---|
| Same webhook delivered twice | Re-running the chain against an already-synced order re-finds the same Person/Product/Order/Line Item rows; nothing new is written, and the Order's Sync Status = Synced check skips the remaining steps entirely. |
| Retry after a partial failure | Every step is independently idempotent. Re-running the same or a fresh delivery simply picks up wherever it stopped — already-created rows are found, not duplicated — and Sync Status staying Pending is itself the signal a retry is still owed. |
| Returning customer | Person upsert by lowercased email finds the existing record instead of creating a second one — true whether the customer is a guest or has an account. |
| Same product across multiple orders | Product upsert by SKU finds the existing Product; only a new Order Line Item pointing at it is created per order. |
| Multi-product orders, variations, add-ons | Every Woo line item — including variations and the paid add-on modeled as its own line item — becomes its own Order Line Item row against the same Order. |

Signature verification additionally ensures only genuine WooCommerce-
originated requests ever reach this chain, so dedup logic only ever has to
reason about legitimate retries, not forged traffic.

---

## 5. Demonstration — all 7 required scenarios, executed with real evidence

Every scenario below was run for real against the live stack — real WP-CLI
orders, real n8n executions, real Twenty GraphQL reads as evidence, not a
dry run. Full query-by-query detail is in `demo-results.md`.

| # | Scenario | Result |
|---|---|---|
| 1 | New customer | New guest customer → 1 new Person, 1 Order, 1 Line Item |
| 2 | Returning customer | 3rd order for an existing customer resolves to her existing Person id, not a new one |
| 3 | Multi-product + variation + add-on | 1 order, 3 correctly-priced Line Items in a single sync |
| 4 | Product reused, historical price preserved | Product's live price updated; two earlier orders' Line Item snapshots stayed unchanged |
| 5 | Duplicate webhook delivery | Identical signed payload replayed 3× → exactly 1 Order / 1 Line Item, not 3 |
| 6 | Fail partway, then retry | Simulated mid-chain crash (Person/Product/Order created, no Line Items yet), followed by a clean, non-duplicating retry through the real production workflow |
| 7 | Both Twenty automations fire | ARR: Amount → $10,000, ARR recomputed to $120,000 exactly, no self-trigger. Email: a fresh order run end-to-end produced one correctly-addressed, correctly-personalized email. |

---

## 6. Engineering decisions & incidents

Findings from the build, in the order they happened — kept here because how
each was caught matters as much as the fix.

**1 — A stale blocker on the status board.** The project's own tracking
board described the webhook secret and CRM API key as missing. Direct
inspection of the running containers showed both were already populated and
valid — a prior session had fixed it without updating the record. The
webhook's stored secret was re-synced belt-and-suspenders anyway, and the
board was corrected. *Takeaway: a status board is a claim, not a fact —
worth checking live system state before trusting it, including your own
project's.*

**2 — A silent 404 on every real webhook delivery.** Before:
`/webhook/WooCommerce-orders`. After: `/webhook/woocommerce-orders`. n8n's
webhook node was registered with a mixed-case path, while WooCommerce's
actual delivery URL — and the project's own documented path — used
lowercase. n8n webhook paths are case-sensitive, so **every real delivery
had been returning 404 before this fix**, regardless of whether the
signature-verification logic was correct. Found and fixed by exporting the
workflow, correcting the path, re-importing, and restarting to reload n8n's
webhook registry (plus removing a stale duplicate route left behind in its
database). Confirmed with direct requests: the corrected path now responds
200, the old path now correctly 404s. Verification didn't stop at the fix —
real orders were then flipped through real status transitions and traced
through n8n's own execution log to confirm the whole gate behaves correctly
against live traffic, not just a manual test payload.

**3 — A "100% built" CRM data model that wasn't there.** While starting the
Twenty automations, the Order/Product/Order Line Item objects — recorded as
fully built — turned out not to exist. Confirmed two independent ways:
Twenty's own metadata API listed only the built-in objects, and a direct
read of Twenty's Postgres metadata tables (bypassing any API-key scoping)
returned zero matching rows. GraphQL schema introspection confirmed it a
third time. The root cause (never created vs. later wiped) was left
undetermined rather than guessed at. With that confirmed and the owner's
sign-off to proceed, the entire data model — three objects, every field, all
three relations including both inverse sides — was rebuilt through Twenty's
own metadata API, working from the exact request shapes read out of the
running container's compiled source rather than assumed. It was then proven
with a live round trip: one real record created per object, relations
confirmed to resolve in both directions, a duplicate SKU and a duplicate
order number each attempted and correctly rejected by Twenty's own
uniqueness constraint — the exact guarantee the sync chain's dedup logic
depends on — and every test record then deleted and confirmed gone.

**4 — "It's fixed" needed to be checked, not trusted, eight times running.**
Both Twenty automations live entirely inside Twenty's own workflow builder,
which has no API for step-level wiring — every fix had to be clicked through
in the browser by the project owner, then re-verified from scratch (direct
database reads plus a real live functional test, never just "the UI looks
configured"). That discipline caught real, specific bugs a visual check
would have missed: a Code step's input schema silently staying empty because
the underlying function used an untyped parameter instead of a typed,
destructured one; an Update Record step reading the wrong source field
(writing ARR = Amount instead of Amount x 12); a customer lookup step
filtered on the Order's own id instead of the customer's id (first causing
an empty match, then causing the workflow to fail outright once other
wiring improved); and a Send Email step with a hardcoded test address
instead of the real customer's. Each was root-caused against Twenty's own
compiled source and re-tested live before being marked done. Both
automations are now confirmed genuinely working end-to-end, not reported
working.

---

## 7. Limitations & open items

- **Paid add-ons are separate line items, not native Woo add-ons.**
  WooCommerce core has no built-in paid-add-on concept. Modeling the
  audiobook add-on as its own order line item is a deliberate simplification
  for this build, not an oversight.
- **No purchased domain.** Hostnames come from sslip.io wildcard DNS tied to
  the Elastic IP. If that IP ever changes, every domain and the WooCommerce
  webhook delivery URL need updating together.
- **Single host, no HA.** No failover for any component. Acceptable for a
  demo build; production would need managed/replicated databases and
  multiple app instances.
- **Twenty's workflow builder is UI-only for step-level wiring.** Confirmed
  via full schema introspection and by calling the real workflow-builder
  mutations directly: the Code step's input/output wiring and the Send Email
  step's mailbox connection are backed by internal objects with no exposed
  API. Both automations were built by a human click-through in Settings →
  Workflows, then independently re-verified from scratch — see incident 4
  above.
- **The completed-order email's HTML part is cosmetically double-escaped**
  in the test mailbox's HTML view (the plain-text part renders correctly,
  and all data in both parts — customer, line items, total — is accurate).
  Not chased further since the email's substance is already fully correct.
- **WordPress's Action Scheduler queue (WP-Cron) is pseudo-cron**, not a
  real timer — it only runs due jobs when something hits the site, so a
  completed-order webhook can sit queued longer than expected on a quiet,
  low-traffic instance. Observed once during the final demonstration and
  resolved with a legitimate "run what's due now" queue flush, not a
  fabricated trigger. Real production traffic, or an external cron hitting
  `wp-cron.php` on an interval, avoids this.
- **Order Line Item dedup rides on the parent Order's gate**, rather than a
  single composite uniqueness constraint on the line item itself (an order
  is only ever line-itemed once, since reruns against an already-synced
  order skip line-item creation). A modeling trade-off worth knowing, not a
  silent gap.
- **Single host, no HA; no purchased domain** (see Architecture) — both
  acceptable trade-offs for a demo build, not oversights.

---

## 8. Current status

All functional categories are complete and independently verified. The only
remaining step is the project owner's own final review, commit, and
submission.

| # | Category | Weight | Progress | Note |
|---|---|---|---|---|
| 1 | Infrastructure — server, compose, HTTPS | 20% | 100% | Verified live. |
| 2 | Shop + test data | 15% | 100% | Test orders staged and seedable. |
| 3 | Twenty data model + API access | 10% | 100% | Rebuilt after incident 3 above; verified via full round trip. |
| 4 | Webhook + security gate | 10% | 100% | Verified against live WooCommerce traffic. |
| 5 | Sync chain — upserts, dedup, retry | 20% | 100% | Built and verified end-to-end against real production orders. |
| 6 | Twenty automations — email + ARR | 10% | 100% | Both verified working end-to-end via live functional tests — see incident 4. |
| 7 | Demonstration — 7 scenarios | 7% | 100% | All 7 executed with real evidence in `demo-results.md`. |
| 8 | Repo, README, deliverables | 8% | 98% | Everything complete except the owner's final commit + submission. |

**Weighted total: 99.8%.** Every functional part of this build is finished
and independently verified; what remains is the owner's own review and
submission step.

---

*Prepared from the project's live status board and repository state,
2026-07-22. Full setup instructions, data-model rationale, and an AI-tools
disclosure note live in this repository's `README.md` and `AI_TOOLS.md`.*
