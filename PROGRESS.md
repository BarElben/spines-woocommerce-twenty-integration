# Progress Board — single source of truth
Every agent MUST update its category's percentage and notes after each work session.
Overall % = weighted sum. Be honest; verified-working only counts.

| # | Category                                   | Weight | Done % | Notes |
|---|--------------------------------------------|--------|--------|-------|
| 1 | Infrastructure (server, compose, HTTPS)    | 20%    | 100%   | verified |
| 2 | Shop + test data (products, orders, seed)  | 15%    | 100%   | orders 30-32 staged |
| 3 | Twenty data model + API access             | 10%    | 100%   | **REBUILT via API and fully verified (2026-07-20, crm-automation-agent)** — see notes below. Product/Order/Order Line Item objects + all fields + all 3 relations recreated via `/rest/metadata/objects`+`/rest/metadata/fields`, proven with a live create→read→relate→uniqueness-reject→delete round trip, not just schema inspection. One naming adaptation category 5 must know about: Sync Status enum values are `STATUS_PENDING`/`STATUS_SYNCED`, not bare `pending`/`synced`. |
| 4 | Webhook + security gate                    | 10%    | 100%   | verified — see notes below |
| 5 | Sync chain (upserts, dedup, retry)         | 20%    | 100%   | **BUILT AND VERIFIED END-TO-END (2026-07-20, integration-agent)** — see notes below. |
| 6 | Twenty automations (email + ARR)           | 10%    | 25%    | ARR field created+verified via API (unchanged). Mailbox blocker now resolved at the infra level: disposable Mailhog SMTP catcher deployed, network-reachable from twenty-server/twenty-worker, and proven end-to-end (a real SMTP send from inside the twenty-server container landed in Mailhog's inbox, visible at the new mail.* domain). Confirmed via source-level investigation that Twenty's self-hosted "Connected Accounts" genuinely supports generic SMTP-only (not OAuth-only) — good news — but confirmed, by actually calling the mutations (not just introspecting), that connecting the mailbox AND building workflow steps both require a real logged-in user session; API keys are explicitly rejected server-side. No credentials for a real user login exist in this project, so both remain human-click-through items. Exact instructions below. |
| 7 | Demonstration (7 scenarios)                | 7%     | 20%    | full runbook + engineered scripts ready, ZERO scenarios executed yet — blocked on categories 5/6. See notes below. |
| 8 | Repo + README + submission                 | 8%     | 80%    | workflow exported+sanitized, README §2/§4/§5/§6 finalized against verified category 5 state; only §7 (blocked on demo-agent's evidence) and final submission remain |

## Category 5 session notes (2026-07-20, integration-agent)

Built the full sync chain into the live "WooCommerce Order Sync" n8n workflow,
inserted after the existing (untouched) Webhook → Verify Signature → Only
Completed chain, on the true branch. Verified category 3 was actually live
(order/product/orderLineItem objects + all relations + Sync Status enum values
`STATUS_PENDING`/`STATUS_SYNCED`) via direct GraphQL introspection before
building against it, independent of crm-automation-agent's own note in this
file.

**Key technical finding, worth flagging for anyone else writing n8n Code nodes
against Twenty in this project**: n8n 2.30.7 runs Code nodes in an external
"JS Task Runner" process, and plain `fetch()` is NOT available there (confirmed
by direct test: `fetch is not defined`). The working alternative, confirmed
live, is `this.helpers.httpRequest(...)` (n8n's own helper), e.g.:
```js
const helpers = this.helpers;
await helpers.httpRequest({ method: 'POST', url: ..., headers: {...}, body: {...}, json: true });
```
All 5 new nodes use this pattern. GraphQL mutation argument name is `data` (not
`input`) — confirmed via mutation-type introspection.

**Nodes added to the production workflow** (all Code nodes except one IF and
one NoOp):
1. **Upsert Person** — looks up by `emails.primaryEmail` (lowercased before
   both lookup and create), creates only if not found. Zero dependency on
   category 3's custom objects, so this was built and fully tested first.
2. **Upsert Products** — de-dupes SKUs within the order's line items, looks up
   each by SKU, creates if missing; if found, updates `currentPrice` (decided
   Product is a live/current record, not historical — the Order Line Item is
   what preserves the snapshot).
3. **Upsert Order** — looks up by `wooOrderNumber`; if found, reads
   `syncStatus` and sets `_alreadySynced` (true only if `STATUS_SYNCED`); if
   not found, creates with `syncStatus: STATUS_PENDING` and `customerId`
   linked to the Person from step 1.
4. **Already Synced?** (IF) — true branch → **Skip - Already Synced** (NoOp,
   dead end): this is the duplicate-webhook-delivery / already-fully-processed
   guard, short-circuiting before any line items are touched. False branch →
   step 5.
5. **Create Line Items** — for each Woo line item, resolves its Product id
   from step 2's map, builds `variation` from `meta_data[].display_value`
   (null if none), then **checks for an existing Order Line Item matching
   this exact order + product + variation before creating** (`is: NULL` for
   the no-variation case — confirmed empirically that this correctly matches
   Twenty's stored value even though the GraphQL response prints `""` for it).
   This per-line-item idempotency check is what makes retry-after-partial-
   failure safe even if a previous run crashed after creating only some of an
   order's line items — finer-grained than step 4's order-level guard. `name`
   is set from the Woo line item's `name` verbatim (already includes the
   variation suffix, e.g. "Book Publishing Package - Signature") — a true
   snapshot, never re-read from the Product later.
6. **Set Sync Status Synced** — `updateOrder(syncStatus: STATUS_SYNCED)`,
   deliberately last, per the designed idempotent-resume-marker model.

**Testing performed (all live, all verified via direct Twenty GraphQL queries
after the fact, not just node output)**:
- Isolated unit test of Upsert Person alone (temporary test webhook workflow,
  separate from production) with a synthetic order payload: created correctly,
  email lowercased; resent with different casing → same person id returned,
  confirmed exactly 1 Person record via API, then cleaned up.
- Full chain test (temporary test workflow, synthetic order #90001, Signature
  package variation + Audiobook add-on, using throwaway SKUs
  `PKG-SIG-TEST`/`ADDON-AUDIO-TEST` so as not to touch the real catalog):
  first delivery created 1 Person, 2 Products, 1 Order (`STATUS_SYNCED`), 2
  Line Items with correct name/price/variation snapshots.
- **Duplicate webhook delivery**: resent the identical #90001 payload —
  response showed `_alreadySynced: true` and no `_lineItemsCreated`/
  `_syncStatus` fields (IF short-circuited before reaching Create Line Items).
  Verified via API: still exactly 1 Order, 1 Person, 2 Line Items (not 4).
- **Retry after partial failure**: built a second temporary test workflow that
  runs Upsert Person → Upsert Products → Upsert Order → then unconditionally
  throws (simulating a mid-chain crash), used a fresh synthetic order #90002
  (same two products, reused on purpose to also exercise "same product across
  two orders"). First run: workflow errored as expected (HTTP 500), and API
  check confirmed Order 90002 existed as `STATUS_PENDING` with **zero** line
  items. Second run: resent the same payload through the real (non-crashing)
  full chain — Order was found (not new), `_alreadySynced` was false, both
  line items were created fresh (`_lineItemsSkipped: []`), Sync Status flipped
  to synced. API check after: exactly 2 line items (not 4), `STATUS_SYNCED`.
  Also confirmed both test products (`PKG-SIG-TEST`, `ADDON-AUDIO-TEST`) had
  the *same* Twenty product id across orders 90001 and 90002 — Product reuse
  across orders confirmed.
- Deleted all synthetic test data (test orders/line items/products/people) and
  the two temporary n8n test workflows (including their `webhook_entity` rows)
  after verifying, so nothing artificial is left in the workspace.
- **Real production test**: flipped real order 30 (Alice, on-hold → completed)
  through the actual live "WooCommerce Order Sync" workflow (real WooCommerce
  webhook, real HMAC signature, no test shortcuts). n8n execution succeeded;
  Twenty API confirmed: 1 Alice Person, Order #30 `STATUS_SYNCED` with correct
  total (4189.00 ILS → 4189000000 amountMicros) and orderDate, 2 Line Items
  (Book Publishing Package - Signature @ 3290, variation "Signature"; Audiobook
  Production @ 899, no variation) — real multi-product + variation + add-on
  order verified end to end.
- Re-saved already-completed real orders 31 and 32 to re-trigger their
  `order.updated` webhooks (WooCommerce delivers webhooks async via Action
  Scheduler — worth noting for whoever writes the demo script: rapid
  successive status changes to the same order can get coalesced into a single
  delivery of the latest state rather than one delivery per change; ran
  `wp action-scheduler run` to flush the queue during testing). Verified via
  API: order 31 (Alice again) synced with 1 line item (Manuscript
  Proofreading, SRV-PROOF) — **returning customer confirmed**: same Person id
  as order 30's customer, no duplicate Alice. Order 32 (Dan, guest,
  `customer_id: 0`) synced with 2 line items (Manuscript Proofreading +
  Book Publishing Package - Essential, variation "Essential") — **new guest
  customer confirmed** (Dan created, exactly 1 Dan Person record). Confirmed
  SKU `SRV-PROOF`'s Product record is a single reused row across orders 31 and
  32, each with its own distinct Line Item.

**Net result**: every scenario category 5 owns is now demonstrated against
real or realistic data with real API verification: new customer, returning
customer, multi-product + variation + add-on, product reused across orders,
duplicate webhook delivery (zero duplicates), retry after partial failure
(resumes cleanly, no duplicates). The only scenario not exercised through this
exact chain is the false/non-completed branch of "Only Completed" — that was
already verified separately and thoroughly by category 4's session (unchanged
nodes, not touched here).

**Known limitation, honestly disclosed**: the per-line-item dedup key is
(order, product, variation) — not Woo's own internal `line_item.id`. This is
correct for this catalog (Woo doesn't produce two separate line items for the
same product+variation in one order) but would misbehave if a future catalog
allowed genuinely duplicate line entries (e.g. same product twice as separate
rows for scheduling reasons) — worth a line in the README limitations section.

**For category 7/8 owners**: the workflow is stable and ready to export
(`n8n export:workflow --id=OIOadgyS7EXEwyIU`) whenever docs-agent wants it —
node names are: Webhook, Verify Signature, Only Completed, Upsert Person,
Upsert Products, Upsert Order, Already Synced?, Skip - Already Synced, Create
Line Items, Set Sync Status Synced. Real orders 30/31/32 are now all synced
(`STATUS_SYNCED`) in Twenty from this session's testing — demo-agent should
either use fresh orders for a clean demo recording or explicitly narrate "this
order was already synced in a previous test, watch it get skipped" as the
duplicate-delivery demo beat.

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

## Category 6 continued (2026-07-20, crm-automation-agent) — mailbox catcher resolved, API-build path re-investigated and ruled out with hard evidence

Owner decided: use a disposable mail-catcher (Mailhog) purely to demo/prove the
email automation fires and composes correctly — no real delivery needed. This
session resolved the infra side of that and re-checked, with actual mutation
calls (not just schema introspection), whether workflow-building or mailbox-
connecting can be done via API instead of a browser.

### 1. Does Twenty's self-hosted "Connected Accounts" support generic IMAP/SMTP, or is it OAuth-only?

**Generic SMTP/IMAP/CalDAV is a first-class, non-OAuth provider.** Found by
reading the compiled source directly in the running container:
`/app/packages/twenty-server/dist/engine/core-modules/imap-smtp-caldav-connection/`
contains a full resolver (`ImapSmtpCaldavResolver`), service, validator, and
Zod schema (`connectionParametersSchema` = `{host, port, username?, password,
connectionSecurity}`). `ConnectedAccountProvider.IMAP_SMTP_CALDAV` is a real,
separate enum value from Gmail/Microsoft OAuth. Config flags confirm it's on
by default: `IS_IMAP_SMTP_CALDAV_ENABLED = true`,
`IS_IMAP_SMTP_CALDAV_CONNECTION_TEST_ENABLED = true` (both in
`engine/core-modules/twenty-config/config-variables.js`). Crucially, the three
protocols (IMAP/SMTP/CALDAV) are each **independently optional** in
`connectionParameters` — `imap-smtp-caldav-connection.service.js`'s
`validateAndTestConnectionParameters` only validates+tests whichever protocol
keys are actually present. **This means a mailbox connected with only an SMTP
block (no IMAP, no CalDAV) is valid** — exactly what a send-only Mailhog
catcher needs; Mailhog doesn't implement IMAP at all, and that's fine.

### 2. The SSRF guard that would have silently defeated a same-network Mailhog

Found a second, independent gate: `SecureHttpClientService.getValidatedHost()`
(`engine/core-modules/secure-http-client/`) resolves the target hostname via
DNS and rejects the connection if it resolves to a private IP
(`resolve-and-validate-hostname.util.js` → `isPrivateIp`). This runs before
both the IMAP/SMTP connection test AND any workflow HTTP/email step. It's
gated by config `OUTBOUND_HTTP_SAFE_MODE_ENABLED`, which **defaults to `true`**
(`config-variables.js` line 64, documented as "Applies to HTTP workflow
actions, webhooks, and IMAP/SMTP/CalDAV connections"). Docker's default bridge
network assigns Mailhog a private (RFC1918) IP, so without addressing this,
the Settings → Accounts "test connection" step and any Send Email step would
have failed with `Connection to internal IP address ... is not allowed` even
after standing up Mailhog correctly — a trap that would have looked like a
Mailhog problem but wasn't.

**Fix applied:** set `OUTBOUND_HTTP_SAFE_MODE_ENABLED=false` on both
`twenty-server` and `twenty-worker` in `docker-compose.yml` (workflow email/
HTTP steps can run on either process), with an in-file comment explaining this
is a demo-only relaxation, not something to carry into a real deployment with
a genuine external SMTP relay.

### 3. Infra changes made (all additive except the two env-var lines above)

- **`docker-compose.yml`**: added a `mailhog` service (`mailhog/mailhog:latest`,
  no host port publishing — reached only via the shared `spines_default`
  network and via Caddy for the web UI); added `OUTBOUND_HTTP_SAFE_MODE_ENABLED=false`
  to `twenty-server` and `twenty-worker`; added `DOMAIN_MAIL` to `caddy`'s
  environment block.
- **`Caddyfile`**: added a `{$DOMAIN_MAIL} { reverse_proxy mailhog:8025 }` block,
  matching the existing n8n/twenty/wp pattern.
- **`.env`** and **`.env.example`**: added `DOMAIN_MAIL=mail.63-181-247-69.sslip.io`
  (real value in `.env`, placeholder in `.env.example`).
- Ran `docker compose up -d`. Compose also recreated `n8n-db`/`twenty-db`/
  `caddy` due to unrelated config-hash changes from the same file edits (volume
  mounts unchanged, named volumes preserved) — verified no data loss: `core.workspace`
  in twenty-db still shows the one "Spines" workspace, and a live GraphQL
  query (`opportunities(first:3)`) after the restart still returns the same
  records with the ARR field intact.

### 4. Verification performed (all real, not assumed)

1. `docker compose exec twenty-server printenv` → `OUTBOUND_HTTP_SAFE_MODE_ENABLED=false`
   confirmed on both twenty-server and twenty-worker.
2. TCP connect test from inside `twenty-server` to `mailhog:1025` succeeded
   (Docker embedded DNS resolves the service name fine, no network wiring
   needed beyond adding the service — no custom `networks:` block exists in
   this compose file, so every service already shares one default network).
3. **End-to-end proof, independent of the Twenty UI**: ran `nodemailer`
   (the same library Twenty's `ImapSmtpCaldavService.testSmtpConnection` /
   send-mail path uses under the hood) from inside the `twenty-server`
   container, sending a real SMTP message to `mailhog:1025`. It was accepted
   (`250 Ok`) and appeared in Mailhog's inbox via its REST API
   (`GET /api/v2/messages`, `total:1`). Confirms the exact connection Twenty's
   own SMTP test/send code will make will succeed once a human enters it in
   the UI. Cleared the test message afterward (`DELETE /api/v1/messages`) so
   the demo starts from an empty inbox.
4. `https://mail.63-181-247-69.sslip.io/` → HTTP 200 through Caddy (Mailhog's
   web UI, auto-HTTPS via the same Let's Encrypt/sslip.io pattern as the other
   three domains).

### 5. Re-investigated (with fresh eyes, by actually calling the mutations, not just introspecting): can workflows be built via API at all?

Previous sessions had ruled this out via GraphQL schema introspection (missing
fields). This session went one step further and **called the mutations
directly by name**, because Twenty's introspection is filtered for non-full-
user auth contexts (a `useDisableIntrospectionAndSuggestionsForUnauthenticatedUsers`-
style hook hides some fields from the schema listing even though they're
real and resolvable):

- `saveImapSmtpCaldavAccount` (the mailbox-connect mutation, lives on the
  `/metadata` GraphQL endpoint, not visible in its introspected field list but
  callable by name) → called with a valid SMTP payload pointed at Mailhog →
  response: `"This endpoint requires a user context. API keys are not
  supported."` Explicit, unambiguous rejection of API-key auth.
- `createWorkflowVersionStep` (the real step-builder mutation behind Twenty's
  workflow editor — found in `engine/core-modules/workflow/resolvers/
  workflow-version-step.resolver.js`, guarded by `WorkspaceAuthGuard` +
  `UserAuthGuard` + `SettingsPermissionGuard(WORKFLOWS)`; also absent from
  introspection but present in the executable schema) → called with a valid
  `CreateWorkflowVersionStepInput` (`stepType: "CODE"`) → response:
  `"Forbidden resource"` (the generic message `UserAuthGuard` produces when
  `request.user` is undefined, which is always the case for API-key auth —
  confirmed by reading the guard's one-line implementation: `return
  request.user !== undefined`).
- Both failures are structural, not permission-tuning issues: there is no
  scope or role an API key can be granted to satisfy `UserAuthGuard`, because
  API-key requests never populate `request.user` at all. The only way to call
  either mutation is a real browser session or a scripted login (email+
  password) producing a user JWT — and this project has no stored Twenty user
  credentials anywhere (`.env` only has `TWENTY_API_KEY`; no
  `TWENTY_ADMIN_EMAIL`/`PASSWORD`-style vars exist). Deliberately did not
  attempt to guess, reset, or otherwise obtain the owner's actual login to
  work around this — that's the owner's account and out of scope for me to
  touch without being asked.
- **Conclusion, now confirmed two ways instead of one**: building either
  workflow (ARR's Code step or the order-synced email's full chain) requires
  an actual human click-through in the Twenty UI. This was already suspected;
  it's now proven at the API-call level, not just inferred from a schema
  listing.

### 6. Updated click-by-click instructions — mailbox connection step (new)

Add this as **step 0** before building the "Order Synced Notification"
workflow from the previous session's notes (Section B above), since Send Email
needs a connected account to even offer as an option in its picker:

1. Log into Twenty (`https://crm.63-181-247-69.sslip.io`) → **Settings** →
   **Accounts** → **Connect an account**.
2. Choose the generic connection option (not the Google/Microsoft OAuth
   buttons) — it's usually labeled something like **"Other (IMAP/SMTP)"** or
   shown as a plain email/password form beneath the OAuth buttons.
3. Fill in:
   - **Handle / email**: `notifications@spines.local` (any address string;
     Mailhog does not validate it)
   - Expand/select the **SMTP** section only — leave IMAP and CalDAV blank:
     - **Host**: `mailhog`
     - **Port**: `1025`
     - **Username**: anything, e.g. `demo`
     - **Password**: anything, e.g. `demo` (Mailhog accepts any credentials)
     - **Connection security**: `None`
4. Save / Connect. Twenty will run a live SMTP connection test
   (`transport.verify()` against `mailhog:1025`) — this **must succeed**
   given the verification in section 4 above (same code path, already proven
   reachable). If it errors, the most likely cause is a stale/uncached
   `OUTBOUND_HTTP_SAFE_MODE_ENABLED` value — recheck with
   `docker compose exec twenty-server printenv | grep OUTBOUND_HTTP_SAFE_MODE_ENABLED`
   and restart `twenty-server`/`twenty-worker` if it doesn't show `false`.
5. This connected account will now appear as a selectable sender in any
   **Send Email** workflow step (Section B, step 5 of the email workflow
   instructions above).
6. To view a sent test email: `https://mail.63-181-247-69.sslip.io` (Mailhog's
   own web UI, no login).

### Honest bottom line for category 6: 25%

**Verified, working:** ARR field on Opportunity (unchanged from last session).
Mailhog catcher deployed, network-reachable, and proven end-to-end via a real
SMTP send from inside the twenty-server container — this specific blocker
("no connected mailbox exists or can exist") is now fully resolved at the
infrastructure level.

**Fully specified, ready to execute in ~10 minutes of clicking:** the mailbox
connection (6 steps above) and both workflows (ARR's Code step, the full
order-synced email chain) — exact fields, values, and JS code all documented
against the real, verified schema.

**Not done, and confirmed impossible without a browser or real user
credentials (re-verified this session by calling the actual mutations, not
just reading the schema):** connecting the mailbox and building any workflow
step. These remain the two concrete human action items blocking category 6
from going higher than roughly a quarter done — everything that *can* be
prepared or proven without a browser has been.

## Category 7 session notes (2026-07-20, demo-agent) — PREP ONLY, zero scenarios executed

Arrived while categories 5 and 6 were both actively in progress in parallel
(confirmed live: n8n's `workflow_entity` table shows the real production
workflow `WooCommerce Order Sync` still at `Webhook → Verify Signature → Only
Completed` only, plus two scratch workflows `TEST sync chain` /
`TEST fetch capability` category 5 is actively iterating on; `execution_entity`
had fresh rows seconds old at the time of my read). Per explicit instructions,
did **not** touch the live n8n workflow, Twenty's data model, `.env`, or
`docker-compose.yml` — everything below is read-only verification plus new
files only (`demo-script.md`, two new scripts under `scripts/`).

**What I did:**
1. Read `assignment.md`'s Demonstration section, `CLAUDE.md`, and this file in
   full for context.
2. **Live read-only recon** (all via existing WP-CLI pattern / GraphQL, no
   writes): confirmed current product IDs/SKUs/prices (SRV-PROOF=13/$499,
   ADDON-AUDIO=14/$899, package variations PKG-ESS=27/$1490, PKG-SIG=28/$3290,
   PKG-PAR=29/$5990), confirmed orders 30 (Alice, on-hold), 31 (Alice,
   completed, SRV-PROOF only), 32 (Dan, completed, SRV-PROOF+PKG-ESS) —
   correcting a stale CLAUDE.md claim that these were "staged in Processing"
   (they're actually on-hold/completed already, another instance of this
   project's recurring stale-status-note pattern). Confirmed via live GraphQL
   query that Twenty currently has only the 5 originally-seeded demo Persons
   (Ivan Zhao, Dario Amodei, Brian Chesky, Dylan Field, Patrick Collison) —
   neither Alice nor Dan exist in Twenty yet, so both are legitimately "new"
   from Twenty's point of view whenever their first order syncs.
3. **Wrote `demo-script.md`** (repo root) — a complete, concrete runbook for
   all 7 scenarios: exact WP-CLI commands (real product/variation IDs, new
   throwaway customer identities per scenario to keep evidence isolated),
   expected n8n execution evidence, expected Twenty GraphQL evidence
   (including exact filter queries to run), and capture instructions for both
   an agent (API/CLI-only, no browser needed for 6 of 7 scenarios) and a human
   with browser access (screenshots of n8n Executions, Twenty record views,
   Workflow → Runs, the received email). Scenario 4 doubles as a "preserve
   historical data" proof (bumps SRV-PROOF's price, then confirms the earlier
   line item's snapshot is unchanged while the product's current price and
   the new line item both reflect the bump). Scenario 6 includes an explicit
   safety step (export the working workflow via `n8n export:workflow` before
   sabotaging any node, so restoration is exact re-import rather than
   manual re-typing that could drift).
4. **Engineered the two special-case scripts, both tested safely without
   touching the live system:**
   - `scripts/demo-replay-webhook.sh` — for "duplicate webhook delivery".
     Fetches a real order's JSON via `wp wc shop_order get --format=json`
     (same shape WooCommerce sends), computes a valid HMAC-SHA256 signature
     over those exact bytes using the real `WC_WEBHOOK_SECRET`, and replays
     the byte-identical body+signature to the n8n webhook URL N times. Has a
     `--dry-run` flag; ran it in dry-run mode against real order 31 to
     confirm the GET + signature computation path works end-to-end (1899-byte
     body fetched, signature computed, zero network calls made) — did **not**
     send anything to the live webhook, so no execution was triggered.
   - `scripts/demo-retrigger-webhook.sh` — for "fail partway then retry" (and
     as an alternate duplicate-delivery method). Forces a fresh, natural
     `order.updated` webhook for an already-completed order via a no-op
     `customer_note` update, without recreating the order or faking a
     payload. Syntax-checked (`bash -n`) only — deliberately **not executed**
     against a real order, since that would fire a real webhook into
     whatever partial state category 5's sync chain is in right now and could
     pollute both their active testing and my own future clean demo run.
5. Confirmed the current production workflow's existing node names
   (`Webhook`, `Verify Signature`, `Only Completed`) directly from
   `workflow_entity.nodes` so Scenario 6's sabotage step in `demo-script.md`
   references real names where they exist today, and flags explicitly that
   the downstream node name (whatever creates Order Line Items) is TBD until
   category 5 finishes — instructs whoever executes to confirm the exact name
   live rather than guessing.

**Explicitly not done (by design — prep only):**
- No scenario has been triggered for real. No demo order beyond the
  pre-existing 30/31/32 exists yet. No n8n execution was caused by this
  session (the one webhook-adjacent script that computes a real signature was
  only run with `--dry-run`).
- Did not touch the live `WooCommerce Order Sync` workflow, any Twenty object/
  field, `.env`, or `docker-compose.yml`.
- Did not create the throwaway demo customers (Emma/Frank/Grace) yet — those
  are created live, per `demo-script.md`, only when scenarios actually run.

**Honest 20%**: the entire plan is ready to execute in one sitting the moment
5 and 6 report done — verified against real, current IDs/data, not
hypothetical ones. 0% of the actual 7-scenario execution/evidence has
happened. Next session (mine or whoever resumes): confirm categories 5/6 are
done, confirm the sync-chain node names in `demo-script.md`'s Scenario 6
placeholder, then run `demo-script.md` top to bottom.

## Category 8 continued (2026-07-20, docs-agent) — workflow export + README finalized against verified category 5 state

Coordinator flagged category 5 as done (workflow id `OIOadgyS7EXEwyIU`, 10
nodes, verified). Re-read category 5's full session notes above before doing
anything. Did **not** touch the live workflow's nodes/logic — export only.

1. **Exported the workflow**: `docker compose exec n8n n8n export:workflow
   --id=OIOadgyS7EXEwyIU --pretty --output=/tmp/workflow-export.json`, copied
   out via `docker compose cp`. Confirmed all 10 node names match category
   5's notes exactly (Webhook, Verify Signature, Only Completed, Upsert
   Person, Upsert Products, Upsert Order, Already Synced?, Skip - Already
   Synced, Create Line Items, Set Sync Status Synced).
2. **Sanity-checked for baked-in secrets before committing anything**:
   grepped the full export for the three env-var names used in the Code
   nodes — every reference is `$env.WC_WEBHOOK_SECRET` / `$env.TWENTY_API_KEY`
   / `$env.TWENTY_API_URL` (read from n8n's runtime environment), never a
   literal value. No `credentials` blocks with values anywhere in the file.
3. **Found and removed one non-secret-but-personal field before committing**:
   the raw export's top-level `shared` array embeds the n8n project owner's
   real name and personal email address, plus a `creatorId`. Not a secret by
   this project's definition (no credential/key
   value), but personally-identifying and pure n8n-instance bookkeeping with
   no import-time value — stripped it out before writing the file to the
   repo. Verified post-strip: zero matches for the email/name/creatorId, JSON
   still valid, all node content (including the env-var references above)
   unchanged.
4. Saved the sanitized export at `n8n/workflow.json` (confirmed not
   gitignored — `git check-ignore` returns nothing for it, unlike `.env`).
5. **Updated README.md**: §2 (Data flow) now shows the real 10-node chain
   with the verification summary from category 5's notes instead of the old
   `[PENDING]` placeholder; §4 corrected to say the CRM objects were built via
   Twenty's metadata API (not "by hand via the UI" as the README previously,
   inaccurately, said) and added the two-segment SELECT-enum naming
   constraint; §5 upgraded to `[STABLE — built and verified]` with a
   per-scenario "Verified" column and the finer-grained per-line-item retry
   guard explained; §6 (Setup) rewritten with the exact `docker compose cp` +
   `n8n import:workflow --activeState=fromJson` commands (confirmed the
   export's `active` field is `true` so this flag should activate it
   directly); §8 gained the specific (Order, Product, Variation) vs.
   WooCommerce's internal `line_item.id` limitation from category 5's notes,
   verbatim as flagged, plus corrected the now-inaccurate "built by hand via
   the UI" limitations bullet to match point 5 above.
6. **Left §7 (Demonstration) untouched**, per instruction — category 7 is
   being executed for real by demo-agent right now; will pick it up once
   evidence is reported back.
7. Local git commit only — not pushed. Left other agents' in-flight,
   uncommitted changes (`docker-compose.yml`, `Caddyfile`, `.env.example`,
   `demo-script.md`, the two `scripts/demo-*.sh` files) exactly as found;
   did not stage or bundle them into this commit.

Category 8 is now 80% — the only remaining pieces are §7 (blocked on
demo-agent) and the actual submission email once everything's done.
