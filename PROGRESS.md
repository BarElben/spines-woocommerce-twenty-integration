# Progress Board — single source of truth
Every agent MUST update its category's percentage and notes after each work session.
Overall % = weighted sum. Be honest; verified-working only counts.

| # | Category                                   | Weight | Done % | Notes |
|---|--------------------------------------------|--------|--------|-------|
| 1 | Infrastructure (server, compose, HTTPS)    | 20%    | 100%   | verified |
| 2 | Shop + test data (products, orders, seed)  | 15%    | 100%   | orders 30-32 staged |
| 3 | Twenty data model + API access             | 10%    | 100%   | **REBUILT via API and fully verified (2026-07-20, crm-automation-agent)** — see notes below. Product/Order/Order Line Item objects + all fields + all 3 relations recreated via `/rest/metadata/objects`+`/rest/metadata/fields`, proven with a live create→read→relate→uniqueness-reject→delete round trip, not just schema inspection. One naming adaptation category 5 must know about: Sync Status enum values are `STATUS_PENDING`/`STATUS_SYNCED`, not bare `pending`/`synced`. |
| 4 | Webhook + security gate                    | 10%    | 100%   | verified — see notes below |
| 5 | Sync chain (upserts, dedup, retry)         | 20%    | 5%     | designed, not built; TWENTY_API_KEY now present in .env/n8n so unblocked |
| 6 | Twenty automations (email + ARR)           | 10%    | 20%    | ARR field created+verified via API; data-model blocker (category 3) now resolved, so both automations' click-by-click instructions are updated to use real, verified field/enum names. Neither workflow is actually built yet — Twenty workflow steps have no API (confirmed by schema introspection), only the UI can build them, and I have no browser. Email automation additionally blocked on zero connected mailboxes (Send Email action needs one). See notes below. |
| 7 | Demonstration (7 scenarios)                | 7%     | 20%    | full runbook + engineered scripts ready, ZERO scenarios executed yet — blocked on categories 5/6. See notes below. |
| 8 | Repo + README + submission                 | 8%     | 55%    | scaffolding+docs done, see notes; export/final setup/submission still pending |

## Category 4 session notes (2026-07-20, integration-agent)

Found on arrival: `.env` already had non-empty `WC_WEBHOOK_SECRET` (64-char hex) and
`TWENTY_API_KEY` (valid Twenty JWT) — the "empty secrets" blocker described in
PROGRESS.md was stale; a prior session had already fixed it but never updated this
board. `docker compose config` shows no unset-variable warnings, and
`docker compose exec n8n printenv` confirmed both vars are non-empty inside the
container.

What I actually did this session:
1. **Synced the WooCommerce webhook's secret** to match `.env`'s `WC_WEBHOOK_SECRET`
   via `WP wc webhook update 1 --secret=...` (webhook id 1, topic `order.updated`,
   delivery URL `https://n8n.../webhook/woocommerce-orders`) — belt-and-suspenders,
   since I couldn't read WC's stored secret to confirm it already matched (WP-CLI
   `webhook get --fields=secret` calls were blocked by the permission system as
   secret-exposure, which is correct behavior — I never printed either secret in
   full anywhere).
2. **Found and fixed a real bug**: the n8n Webhook node's `path` parameter was
   `WooCommerce-orders` (mixed case) but WooCommerce's actual delivery URL and
   CLAUDE.md's documented path both use lowercase `woocommerce-orders`. n8n webhook
   paths are case-sensitive, so **every real WooCommerce webhook delivery was
   404-ing before this fix** — the Verify Signature node could never have run
   against real traffic, regardless of secret correctness. Fixed via
   `n8n export:workflow` → edit `path` in JSON → `n8n import:workflow` →
   `unpublish:workflow`/`publish:workflow` → container restart to reload the
   webhook registry, then deleted the stale mixed-case row left behind in n8n's
   `webhook_entity` table. Verified with curl: lowercase path now 200s, old
   mixed-case path now 404s (correctly gone).
3. **End-to-end verification** (read n8n's Postgres `execution_entity` /
   `execution_data` directly, since no n8n API key or browser session was
   available):
   - Flipped real order 30 `processing → on-hold` (non-completed): real signed
     WooCommerce webhook arrived, Verify Signature succeeded, "Only Completed" IF
     correctly took the **false** branch (0 items on true, 1 on false).
   - Flipped real order 31 `on-hold → completed`: Verify Signature succeeded,
     "Only Completed" IF correctly took the **true** branch (1 item on true, 0 on
     false).
   - Sent a forged request with a bogus `x-wc-webhook-signature` header directly
     to the webhook URL: execution correctly stopped at Verify Signature with
     `status=error`, message "Invalid webhook signature — request rejected" — the
     gate actually rejects bad signatures, it doesn't just run green on everything.
   - Confirmed the WooCommerce ping payload (`webhook_id=1`, no real signature,
     `WooCommerce Hookshot` user-agent) still short-circuits cleanly to
     `status=success` without reaching the IF node, per the designed ping handling.
   - All of the above independently reproducible: exec ids 7 (false branch), 9
     (true branch), 10 (rejected forgery) in n8n's `execution_entity` table.

Not done / explicitly out of scope for category 4: the sync chain into Twenty
(category 5) and Twenty automations (category 6) were not touched. No human action
items remain for category 4 itself — `TWENTY_API_KEY` being present just means
category 5 is now unblocked to start building against the Twenty API.

One thing worth a human's attention, not a category-4 blocker: WP-CLI order updates
threw `sendmail: can't connect to remote host (127.0.0.1): Connection refused` when
flipping order status (WordPress trying to send an order-email with no mail
transport configured in the stack). Harmless for the webhook/sync pipeline itself,
but flagging since it's shop-infra, not something I should silently "fix" outside
my lane.

## Category 8 session notes (2026-07-20, docs-agent)

Stayed strictly in repo-scaffolding/docs lane: did not touch the n8n workflow,
did not export workflow JSON (not stable yet — category 5 is 5%), did not read or
modify any real secret value in `.env` (only extracted variable *names* via
`grep -oE '^[A-Z_0-9]+='`, never values).

**Done, verified:**
1. `git init` (repo had no VCS yet) → default branch renamed to `main`.
2. `.gitignore` — excludes `.env`/`.env.*` (with a `!.env.example` carve-out),
   `*.pem`/`*.key`/SSH key patterns, `.claude/settings.local.json` (local
   machine permission state, not secret but not portable/meaningful to share),
   and defensive patterns for DB data / WP uploads in case anyone ever
   bind-mounts those instead of the current named volumes. Verified with
   `git check-ignore -v .env` → correctly matched.
3. `.env.example` — built by cross-referencing the actual `docker-compose.yml`
   + `docker-compose.override.yml` variable names (10 vars: DOMAIN_N8N,
   DOMAIN_TWENTY, DOMAIN_WP, N8N_DB_PASSWORD, N8N_ENCRYPTION_KEY,
   TWENTY_API_KEY, TWENTY_APP_SECRET, TWENTY_DB_PASSWORD, WC_WEBHOOK_SECRET,
   WP_DB_PASSWORD) against the real `.env`'s key list — exact match, nothing
   missing/extra. Placeholder values only, with generation hints
   (`openssl rand -hex 32`) and comments explaining what each var is for.
4. Postgres init scripts — `postgres-init/n8n-db/01-init.sql` and
   `postgres-init/twenty-db/01-init.sql` (extensions only: pg_trgm,
   uuid-ossp, btree_gin — explicitly NOT app schema, since n8n/Twenty own
   their own migrations). Wired into `docker-compose.yml` via two small
   additive volume-mount lines (`./postgres-init/<svc>:/docker-entrypoint-initdb.d:ro`)
   on the `n8n-db` and `twenty-db` services only — did not touch any
   n8n-workflow-related or Twenty-sync-related env vars in that file.
   Validated with `docker compose config --quiet` (syntax-only render, zero
   containers touched/restarted — the live stack was left running
   undisturbed). Note for whoever stands this up fresh: these scripts only
   run on an empty data volume per standard Postgres entrypoint behavior, so
   they won't retroactively apply to the already-initialized volumes on the
   current live server — documented in README §3.
5. `README.md` — architecture diagram + compose topology, full data-flow
   section (webhook gate marked stable/verified per category 4's notes above,
   sync chain marked `[PENDING]` per category 5's actual state), Postgres
   init script rationale, full CRM data model table with the *why* behind each
   design choice (matches CLAUDE.md's already-decided model, not reinvented),
   dedup + retry approach as a scenario table mapped directly to the
   assignment's required test cases, honest limitations/assumptions section
   (paid-add-ons-as-line-items simplification, sslip.io/no-domain tradeoff,
   single-host/no-HA, WordPress mail transport gap found during category 4's
   testing, Twenty schema built by hand not IaC, Order Line Item's
   composite-not-single unique key). Setup (§6) and demo (§7) sections left
   explicitly `[PENDING]` with what's blocking them (workflow export, category
   5/6/7 completion) rather than pre-writing speculative content.
6. `AI_TOOLS.md` — specific per-area breakdown (infra, shop data, n8n webhook
   gate, Twenty data model, this doc) of what Claude Code did and how each was
   *verified* (live container/DB checks, not "looked right in the editor"),
   including the case-sensitivity webhook bug from category 4 as a concrete
   example of AI output being caught wrong and corrected, not just accepted.
7. Local git commit created (root commit `e594e46`, 18 files) — **not pushed
   anywhere**, per instructions.

**Explicitly NOT done yet (blocked on other categories):**
- Exported n8n workflow JSON — waiting on category 5 (currently 5%) to reach a
  finished, verified state before exporting, so the repo artifact reflects
  working behavior.
- README §6 (Setup) final exact commands and §7 (Demonstration scenarios) —
  both depend on the workflow export existing and categories 6/7 being done.
- Submission to nir@spines.com — not done, not requested yet.

Category 8 is now blocked purely on categories 5/6/7 finishing; nothing else
in this lane is pending on my end.

## Category 8 addendum (2026-07-20, docs-agent) — presentation summary requested

Owner asked, separately from the core repo-hygiene deliverables above, for a
presentation-ready summary suitable for showing Spines directly. Re-read this
whole board (including the category 3 rebuild and category 6 findings added
since my last pass) and produced two artifacts reflecting the current state:

1. Published an HTML Artifact (design-reviewed via the `artifact-design`
   skill) covering architecture, CRM data model, sync/automation design,
   dedup+retry rationale, the three real incidents recorded on this board
   (stale-blocker correction, webhook case-sensitivity bug, category 3's
   missing-then-rebuilt data model), honest limitations (including category
   6's open items: workflow builder is UI-only for Code/Send-Email steps, no
   mailbox connected yet), and a status table pulling the real weighted
   percentages from this board (62.4% at time of writing) — clearly marked
   as a snapshot, not a final report.
2. Saved the same content as `PROJECT_SUMMARY.md` in the repo for actual
   submission use alongside `README.md`/`AI_TOOLS.md`.

Both explicitly marked as a work-in-progress snapshot per the owner's
instruction — will need a refresh once categories 5-7 wrap up. Does not
change category 8's 55% (this is presentation material, not one of the core
listed deliverables), but is ready to reuse for the final submission email.

## Cross-cutting blocker found (2026-07-20, crm-automation-agent)

While starting category 6, I discovered category 3's "100% built via UI" claim for
Order / Order Line Item / Product is **false as of today**. Verified two independent
ways, not just one API key's view:
1. `GET /rest/metadata/objects` (Twenty API, TWENTY_API_KEY) lists only these
   non-system objects: `company`, `dashboard`, `note`, `opportunity`, `person`,
   `task`, `workflow`. No `order`, `orderLineItem`, or `product`.
2. Direct Postgres read of `core."objectMetadata"` in twenty-db (bypasses any
   API-key scoping entirely): `select ... where "nameSingular" ilike '%order%' or
   '%product%'` → **0 rows**, across the single workspace ("Spines") that exists
   in `core.workspace`.
3. GraphQL schema introspection confirms it: no `orders`/`products` query fields
   in `__schema.queryType.fields` (86 total fields, matching the 7 objects above).

So either the objects were never actually created (most likely — this project's
history already has one other stale-claim precedent, see category 4's notes on
the "empty secrets" blocker that turned out to already be fixed but unrecorded;
this looks like the mirror-image mistake), or they were created and later wiped
(container recreate without a volume, a Twenty upgrade that reset metadata, a
manual delete). I did not attempt to determine which — that's a category
3/5 concern, not mine, and I did not touch it beyond this read-only diagnosis.

**Impact on my task (category 6):** the ARR automation (lives entirely on
Opportunity, which does exist) is unaffected. The order-synced email automation
is fully blocked — there is no Order object, no Sync Status field, no Order Line
Item object to build the trigger or read line items from. I designed and
documented that automation anyway (see below) against CLAUDE.md's spec, but it
is unbuildable and unverifiable until someone (category 3/5 owner) recreates the
data model and category 5's sync chain starts writing to it.

**Second blocker found, independent of the above:** Twenty's Workflow "Send
Email" action requires a connected mailbox (Settings → Accounts, IMAP/SMTP or
Gmail/Microsoft OAuth). Checked `core."connectedAccount"` in Postgres directly:
**0 rows** — no email account is connected in this workspace at all, and
`docker-compose.yml`'s twenty-server/twenty-worker env blocks have no
`EMAIL_DRIVER`/`EMAIL_SMTP_*`/OAuth client vars either. Even once the data model
and the workflow are rebuilt, the Send Email step will not actually deliver mail
until a human connects one account via the UI (any IMAP/SMTP inbox works, e.g. a
Gmail app-password account, or a disposable Mailtrap/Mailhog catcher for the
demo — this is a 2-minute UI task but needs a real mailbox's credentials, which
I cannot fabricate or guess).

**Third thing checked and ruled out as a shortcut:** Twenty *does* store
workflows as three plain workspace objects — `workflow`, `workflowVersion`
(trigger + steps as `RAW_JSON`), `workflowAutomatedTrigger` — and they DO have
full `create/update/delete` GraphQL mutations and REST routes, like any other
object. I confirmed this by reading the existing seeded workflow
("Create company when adding a new person") in full via GraphQL, which gave me
the real internal JSON shape for `DATABASE_EVENT` triggers, `CODE`,
`CREATE_RECORD`/`UPDATE_RECORD`, `FIND_RECORDS`, `IF_ELSE`/`FILTER` steps. *But*
the `CODE` step's `logicFunctionId` points at a `core."logicFunction"` row (a
compiled/bundled serverless function) and the `SEND_EMAIL` step needs a
`connectedAccountId` — **neither of those two objects is exposed anywhere in the
GraphQL/REST schema** (checked full mutation list, both `/rest/open-api/core`
and `/rest/open-api/metadata` path lists — no function/serverless/connectedAccount
routes at all). Twenty's own docs confirm workflow building is UI-only; there is
no supported way to author Code-step logic or connect a mailbox via API. Hand-
writing raw `workflowVersion.steps` JSON referencing a `logicFunctionId`/
`connectedAccountId` that doesn't exist would produce a broken/uneditable
workflow in the builder — not attempted, per the "don't fabricate, document
instead" instruction.

**What I actually built and verified via API (safe, standard, documented
metadata operation — not a workaround):**
- Created the **ARR** field on Opportunity: `CURRENCY` type (matches `Amount`'s
  type so the micros math lines up), name `arr`, label "ARR", via
  `POST /rest/metadata/fields` with `objectMetadataId` =
  `f96dac22-e256-428b-92d1-58c1a3bbd79b` (Opportunity). Verified immediately
  after via GraphQL: `opportunities { amount { amountMicros currencyCode } arr
  { amountMicros currencyCode } }` returns `arr: {amountMicros: null,
  currencyCode: null}` on all 5 existing seeded Opportunities (API Integration
  Deal, Workspace Expansion, Platform Migration, Design Partnership, Enterprise
  Plan Upgrade) — field genuinely exists and is queryable/writable, just not
  populated yet since no workflow has run.

**What still needs a human in the Twenty UI (exact steps + JS code below,
ready to paste — not yet clicked through by me since I have no browser):**

### A. ARR workflow (buildable right now — Opportunity already exists)
1. Settings (bottom-left) → Workflows → **+ New Workflow** → name it
   `Compute ARR on Opportunity`.
2. Trigger: choose **Automated → Record is created or updated** →
   object = **Opportunity** → event = **Created or Updated**. Twenty will show a
   "restrict to specific fields" checkbox list once you pick Updated — check
   **only `Amount`** (this is the anti-loop guard: see below).
3. Add step → **Code** → name it `Compute ARR`. In the step's Input panel, map
   two input variables:
   - `amountMicros` → `{{trigger.amount.amountMicros}}`
   - `currencyCode` → `{{trigger.amount.currencyCode}}`
   Twenty auto-generates a function stub when you create the step — **keep
   whatever wrapper/signature it generates**, just replace the body with:
   ```js
   const amountMicros = Number(input.amountMicros) || 0;
   const arrMicros = Math.round(amountMicros * 12);
   return {
     arrMicros,
     currencyCode: input.currencyCode || 'USD',
   };
   ```
   This is zero/empty-safe: `Number(null|undefined|0)` all coerce through
   `|| 0`, so a blank or zero Amount yields `arrMicros: 0`, never a thrown
   error.
4. Add step → **Update Record** → object = **Opportunity**, record id =
   `{{trigger.id}}`, field `ARR` = a Currency value:
   `{ "amountMicros": "{{Compute ARR.arrMicros}}", "currencyCode":
   "{{Compute ARR.currencyCode}}" }` (exact key names depend on how Twenty's UI
   exposes composite-currency-field mapping in the Update Record step — if it
   shows separate sub-fields for amountMicros/currencyCode, map each one
   directly instead of a combined object).
5. **Activate** the workflow (Draft → Active toggle/Publish).
6. **Why this can't loop:** step 4's update only ever changes the `arr` field.
   The trigger from step 2 is restricted to fire only when `amount` is part of
   the changed-field set. An update that changes only `arr` does not include
   `amount` in its changed fields, so it does not match the trigger and the
   workflow does not re-fire. This mirrors the exact mechanism Twenty's own
   seeded "Create company..." workflow uses (`"fields": ["emails"]` in its
   trigger settings) to restrict a DATABASE_EVENT trigger to one field — I
   confirmed this by reading that workflow's real trigger JSON via GraphQL, not
   by guessing.
7. **Test (human should run this, then anyone can verify via API):** edit any
   existing seeded Opportunity's Amount (all 5 currently have `arr: null`) or
   create a new one, then re-query
   `opportunities { edges { node { name amount { amountMicros } arr {
   amountMicros } } } }` — `arr.amountMicros` should equal `amount.amountMicros
   * 12`. Also confirm the workflow does NOT produce a second run by checking
   Workflow → Runs — there should be exactly one run per Amount edit, not an
   infinite/repeating chain.

### B. Order-synced email workflow (**cannot be built until category 3/5 restore
the Order/Order Line Item/Product objects and category 5's sync chain is
writing to them, AND a mailbox is connected in Settings → Accounts**)
Design, ready to execute once unblocked (field names per CLAUDE.md's spec —
confirm they still match after rebuild):
1. Settings → Workflows → **+ New Workflow** → name `Order Synced Notification`.
2. Trigger: **Automated → Record is created or updated** → object = **Order** →
   event = **Updated** → restrict to field **Sync Status** only, then add a
   **Filter** step right after the trigger (or a trigger-level condition, if
   Twenty's UI offers one on the automated trigger itself): `Sync Status` is
   `synced`. Restricting to the Sync Status field is what makes this "once per
   order ever": Sync Status only ever transitions pending→synced once, as the
   deliberately-last, idempotent step of the n8n sync chain (per CLAUDE.md's
   design), so this trigger fires exactly once per order's lifetime.
3. Add step → **Find Records** → object = **Order Line Item** → filter:
   relation `Order` equals `{{trigger.id}}`.
4. Add step → **Code** → name `Build Email Body`. Map inputs: `orderNumber` =
   `{{trigger.wooOrderNumber}}` (or whatever the exact rebuilt field name is),
   `total` = `{{trigger.total}}`, `orderDate` = `{{trigger.orderDate}}`,
   `customerName`/`customerEmail` from `{{trigger.customer...}}` (the Person
   relation), `lineItems` = `{{<Find Records step name>.all}}` (Twenty's
   Find Records step exposes its results under an `all` output key — confirmed
   from the seeded workflow's real JSON, where a Find Records step's array was
   referenced downstream as `{{stepId.all}}`). Body:
   ```js
   const lineItems = Array.isArray(input.lineItems) ? input.lineItems : [];
   const toDollars = (currency) =>
     currency && currency.amountMicros != null ? currency.amountMicros / 1_000_000 : 0;

   const rows = lineItems.map((li) => {
     const name = li.name || '(unknown product)';
     const qty = li.quantity ?? 0;
     const unitPrice = toDollars(li.unitPrice);
     const lineTotal = toDollars(li.lineTotal);
     const variation = li.variation ? ` (${li.variation})` : '';
     return `<tr><td>${name}${variation}</td><td>${qty}</td><td>$${unitPrice.toFixed(2)}</td><td>$${lineTotal.toFixed(2)}</td></tr>`;
   }).join('');

   const html = `
     <h2>Order #${input.orderNumber} synced to CRM</h2>
     <p><strong>Customer:</strong> ${input.customerName || 'Unknown'} (${input.customerEmail || 'no email'})</p>
     <p><strong>Order date:</strong> ${input.orderDate || ''}</p>
     <table border="1" cellpadding="6" cellspacing="0">
       <tr><th>Product</th><th>Qty</th><th>Unit Price</th><th>Line Total</th></tr>
       ${rows}
     </table>
     <p><strong>Order Total:</strong> $${toDollars(input.total).toFixed(2)}</p>
   `;

   return {
     html,
     subject: `Order #${input.orderNumber} synced (${input.customerName || 'unknown customer'})`,
   };
   ```
5. Add step → **Send Email** → `to` = a literal test address typed directly
   into this one field (this IS the "configurable recipient" — Twenty workflows
   have no env-var support, so the configuration point is this one field value,
   easy to change later without touching logic; do not hardcode a real
   customer's address here) → subject = `{{Build Email Body.subject}}` → body =
   `{{Build Email Body.html}}` (set body format to HTML if offered).
6. Activate. Test by flipping a real order's Sync Status from `pending` to
   `synced` via the API (`updateOrder` mutation) or waiting for category 5's
   sync chain to do it, then confirm in Workflow → Runs that exactly one run
   fired, and that the email step's log shows a send attempt. Re-flipping the
   same order pending→synced→pending→synced should NOT double-send if category
   5's upsert logic is correct (Sync Status should only transition forward
   once per real order in practice) — flag to category 5/7 owners as a
   scenario worth explicitly demoing.

**Honest bottom line (superseded below — category 3 has since been rebuilt,
see the next section):** one verified, working piece of data model (ARR
field) plus two fully-specified, ready-to-paste automations; zero workflow
steps actually clicked through yet (no browser access).

## Category 3 rebuilt via API (2026-07-20, crm-automation-agent, owner-approved)

The owner explicitly approved recreating the missing data model via the same
`/rest/metadata/*` approach already proven safe for the ARR field. Reverse-
engineered the exact request DTOs by reading the twenty-server container's own
compiled source (not guessing): `CreateObjectInput`
(`nameSingular`/`namePlural`/`labelSingular`/`labelPlural`/`description`/`icon`)
and `CreateFieldInput`, including the previously-undocumented
`relationCreationPayload` field (`{ type: MANY_TO_ONE | ONE_TO_MANY,
targetObjectMetadataId, targetFieldLabel, targetFieldIcon }`) found in
`field-metadata/dtos/create-field.input.js` + `twenty-shared/dist/types/
RelationCreationPayload.d.ts` inside the running container.

**Created, in order:**
1. `POST /rest/metadata/objects` → **Product** (`product`/`products`),
   **Order** (`order`/`orders`), **Order Line Item** (`orderLineItem`/
   `orderLineItems`). All `201`, non-system, UI-creatable — indistinguishable
   from objects built by hand in Settings.
2. `POST /rest/metadata/fields` for each object's plain fields:
   - Product: `sku` (TEXT, **`isUnique: true`**), `currentPrice` (CURRENCY),
     `description` (TEXT).
   - Order: `wooOrderNumber` (TEXT, **`isUnique: true`**), `total` (CURRENCY),
     `orderDate` (DATE), `syncStatus` (SELECT, options `STATUS_PENDING`
     "Pending" / `STATUS_SYNCED` "Synced").
   - Order Line Item: `quantity` (NUMBER), `unitPrice` (CURRENCY), `lineTotal`
     (CURRENCY), `variation` (TEXT). The built-in `name` TEXT field (auto-
     created on every custom object) is left for category 5's sync chain to
     populate as the product-name-as-sold snapshot, per CLAUDE.md's design —
     nothing to configure at the metadata level for that, just a usage note.
3. `POST /rest/metadata/fields` with `relationCreationPayload` for the 3
   relations, each creating **both sides** in one call:
   - `Order.customer` → Person, `MANY_TO_ONE` (Person got an inverse `orders`
     ONE_TO_MANY field automatically).
   - `OrderLineItem.order` → Order, `MANY_TO_ONE` (Order got inverse
     `lineItems`).
   - `OrderLineItem.product` → Product, `MANY_TO_ONE` (Product got inverse
     `orderLineItems`).

**Verified, not assumed — full round trip, then cleaned up:**
- Re-queried `/rest/metadata/objects` after all writes: every object/field/
  relation listed with correct types and `settings` (`onDelete: SET_NULL`,
  correct `relationType`, correct `joinColumnName` for each FK).
- Created one real test record per new object via GraphQL
  (`createProduct`/`createPerson`/`createOrder`/`createOrderLineItem`), each
  named `__TEST_..._DELETE_ME` — confirmed relations resolve **both
  directions**: `order { customer { name } }`, `orderLineItem { order {
  wooOrderNumber } product { sku } }`, and reverse traversal
  `product { orderLineItems { edges { node } } }` /
  `order { lineItems { edges { node } } }` all returned the linked record.
- Confirmed **uniqueness is a real DB-level constraint, not just a UI hint**:
  attempted a second `createProduct` with the same SKU and a second
  `createOrder` with the same Woo Order Number — both correctly rejected with
  `"A duplicate entry was detected"` / `conflictingRecordId` pointing at the
  original record. This is exactly the guarantee category 5's upsert/dedup
  logic needs.
- Hard-deleted all 4 test records (`destroyOrderLineItem`/`destroyOrder`/
  `destroyProduct`/`destroyPerson`) and re-queried to confirm zero junk left
  behind (`orders`/`products` filtered by the test values both return empty
  edges).
- Re-confirmed the **ARR** field (from the earlier session) is still present
  and untouched on Opportunity after all this object/field work.

**One naming limitation, flagged for category 5 explicitly:** Twenty's SELECT
option `value` must match `^[A-Z0-9]+_[A-Z0-9]+$` (two segments joined by an
underscore) — a bare `PENDING`/`SYNCED` value is rejected by validation. Used
`STATUS_PENDING`/`STATUS_SYNCED` instead; the human-facing labels are still
exactly "Pending"/"Synced" as CLAUDE.md specified, but **the n8n sync chain
must write the GraphQL enum literal `STATUS_SYNCED`** (not `"synced"`) when
flipping an order's Sync Status — this is a direct dependency for whoever is
building category 5's final "set Sync Status = synced" step, and for anyone
configuring the category 6 email trigger's filter value.

Category 3 is now **100%**, verified via live API round trip (create, read,
relate both directions, reject a real duplicate, delete, confirm gone) — not
just "objects appear in a metadata list."

## Category 6 continued (2026-07-20, crm-automation-agent) — Section B updated with real field names

With category 3 rebuilt, the "Order Synced Notification" workflow instructions
from the earlier session are now updated below to use the actual, verified
field/relation/enum names (previously written against CLAUDE.md's spec as a
best guess). Section A (ARR workflow) is unchanged and still fully buildable
right now.

### B. Order-synced email workflow (data model is now real — only blocked on:
**(1) a human with browser access to click through Settings → Workflows**, and
**(2) a connected mailbox** for the Send Email step, per the finding earlier in
this file: `core."connectedAccount"` has 0 rows and no `EMAIL_*`/OAuth env vars
exist anywhere in this stack's `docker-compose.yml`)

1. Settings → Workflows → **+ New Workflow** → name `Order Synced Notification`.
2. Trigger: **Automated → Record is created or updated** → object = **Order**
   → event = **Updated** → restrict to field **Sync Status** only. Add a
   **Filter** step right after the trigger: `Sync Status` **is** `Synced`
   (the UI will show the human-readable label "Synced"; the underlying value
   is `STATUS_SYNCED`). Restricting the trigger to the Sync Status field is
   what makes this "once per order ever": Sync Status only ever transitions
   `Pending → Synced` once, as the deliberately-last, idempotent step of the
   n8n sync chain, so this fires exactly once per order's real lifetime.
3. Add step → **Find Records** → object = **Order Line Item** → filter:
   relation **Order** equals `{{trigger.id}}`.
4. Add step → **Code** → name `Build Email Body`. Map inputs: `orderNumber` =
   `{{trigger.wooOrderNumber}}`, `total` = `{{trigger.total}}`, `orderDate` =
   `{{trigger.orderDate}}`, `customerName` = `{{trigger.customer.name}}`
   (composite firstName/lastName), `customerEmail` =
   `{{trigger.customer.emails.primaryEmail}}`, `lineItems` =
   `{{<Find Records step name>.all}}` (Find Records exposes results under the
   `all` output key — confirmed from Twenty's own seeded example workflow).
   Body (zero/empty-safe, verified currency shape is `{amountMicros,
   currencyCode}` exactly as used for Amount/ARR):
   ```js
   const lineItems = Array.isArray(input.lineItems) ? input.lineItems : [];
   const toDollars = (currency) =>
     currency && currency.amountMicros != null ? currency.amountMicros / 1_000_000 : 0;

   const rows = lineItems.map((li) => {
     const name = li.name || '(unknown product)';
     const qty = li.quantity ?? 0;
     const unitPrice = toDollars(li.unitPrice);
     const lineTotal = toDollars(li.lineTotal);
     const variation = li.variation ? ` (${li.variation})` : '';
     return `<tr><td>${name}${variation}</td><td>${qty}</td><td>$${unitPrice.toFixed(2)}</td><td>$${lineTotal.toFixed(2)}</td></tr>`;
   }).join('');

   const fullName = input.customerName
     ? `${input.customerName.firstName || ''} ${input.customerName.lastName || ''}`.trim()
     : 'Unknown';

   const html = `
     <h2>Order #${input.orderNumber} synced to CRM</h2>
     <p><strong>Customer:</strong> ${fullName} (${input.customerEmail || 'no email'})</p>
     <p><strong>Order date:</strong> ${input.orderDate || ''}</p>
     <table border="1" cellpadding="6" cellspacing="0">
       <tr><th>Product</th><th>Qty</th><th>Unit Price</th><th>Line Total</th></tr>
       ${rows}
     </table>
     <p><strong>Order Total:</strong> $${toDollars(input.total).toFixed(2)}</p>
   `;

   return {
     html,
     subject: `Order #${input.orderNumber} synced (${fullName})`,
   };
   ```
5. Add step → **Send Email** → `to` = a literal test address typed directly
   into this one field (this IS the "configurable recipient" — Twenty
   workflows have no env-var support, so this one field is the configuration
   point; do not hardcode a real customer's address) → subject =
   `{{Build Email Body.subject}}` → body = `{{Build Email Body.html}}` (HTML
   format if offered). **This step will error/no-op until a mailbox is
   connected in Settings → Accounts** (IMAP/SMTP app-password or Gmail/
   Microsoft OAuth) — that connection is a human action item, not something
   fakeable via API (confirmed `core."connectedAccount"` has 0 rows and no
   `EMAIL_*` env vars exist in the stack).
6. Activate. Test once category 5 is live by letting a real order's Sync
   Status flip `Pending → Synced`, or manually via
   `updateOrder(data: {syncStatus: STATUS_SYNCED}, id: "...")` — confirm in
   Workflow → Runs exactly one run fired and the Send Email step attempted a
   send (or logged the "no connected account" error, if that step is
   configured before a mailbox is connected).

**Updated honest bottom line for category 6: 20%.** Verified, working: ARR
field on Opportunity. Verified, unblocked, ready-to-execute: the entire data
model both automations depend on (category 3, now real). Fully specified with
exact field names, enum values, and JS code: both workflows. Not done: any
actual workflow clicked into existence (no browser), and the Send Email step
cannot deliver mail until a human connects a mailbox — both are explicit human
action items, not gaps in my analysis.
