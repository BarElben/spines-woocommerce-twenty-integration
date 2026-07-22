# AI tools disclosure

This project was built with **Claude Code** (Anthropic's agentic CLI) as the
primary engineering tool throughout — infrastructure setup, WooCommerce shop
configuration, n8n workflow design, Twenty CRM data modeling, automation
design, and this documentation. This note is meant to be specific and honest
about what was actually verified, not a blanket "AI was used" disclaimer.

## Where it was used, and how

**Infrastructure (EC2, Docker Compose, Caddy, security group).** Claude Code
ran the provisioning and compose-file authoring directly against the live
server over SSH/bash. Validated by: `docker compose config` (syntax), `docker
compose ps` / `docker logs` (containers actually healthy), and hitting each
public hostname over HTTPS to confirm Caddy's automatic TLS actually issued
valid certificates — not just "the compose file looks right."

**WooCommerce shop + test data (products, customers, orders).** Created via
WP-CLI (`wp wc ...`) run inside a disposable `wordpress:cli` container.
Validated by re-querying the created objects back out via `wp wc product
list` / `wp wc order list` etc. and cross-checking SKUs/prices/variations
matched what was intended, not just trusting the create command's exit code.

**n8n workflow (webhook + signature verification + routing).** Designed and
implemented in n8n's Code/Webhook/IF nodes. Validated end-to-end against
*real* WooCommerce webhook traffic (not just manually POSTed test payloads):
flipping real order statuses and reading n8n's own Postgres
`execution_entity`/`execution_data` tables directly to confirm which branch
each real execution took, plus a deliberately forged signature to confirm the
gate actually rejects bad requests rather than passing everything through.
This process also caught a real bug — a case-sensitivity mismatch between the
n8n webhook node's registered path and WooCommerce's actual delivery URL,
which meant every real delivery was 404-ing silently — precisely the kind of
thing that "looks correct in the editor" but fails against live traffic, and
was only caught because verification used real webhook deliveries and
database state instead of trusting the workflow's green checkmarks.

**Twenty CRM data model.** Designed (unique keys, relations, snapshot-vs-live
field decisions) collaboratively, then built via Twenty's own metadata API
(`/rest/metadata/objects` + `/rest/metadata/fields`), reverse-engineering the
undocumented `relationCreationPayload` request shape by reading the
twenty-server container's own compiled source rather than guessing. Partway
through the build, these custom objects (Order/Product/Order Line Item) were
found to be *missing* despite an earlier status-board entry claiming they were
done — root-caused via direct Postgres inspection (`core."objectMetadata"`)
and GraphQL schema introspection, then rebuilt with a full live
create→relate→uniqueness-reject→delete round trip, not just re-inspecting the
schema. Design decisions documented in `README.md` §4 include the reasoning
(e.g. why email-lowercased for Person, why SKU for Product, why line items
snapshot name/price instead of live-referencing the Product).

**Sync chain (n8n → Twenty upserts, dedup, retry).** Built as five Code nodes
appended to the production n8n workflow, each doing a lookup-by-natural-key
upsert (email for Person, SKU for Product, Woo order number for Order,
(order, product, variation) for Order Line Item). Validated with live,
verifiable tests, not just green node output: isolated unit test of the
Person upsert; a full synthetic-order run through every step; an identical
duplicate delivery (confirmed zero new records via a follow-up Twenty API
query); a deliberately crashed mid-chain run followed by a real retry
(confirmed no duplicate line items); and three real production orders
(30/31/32) flipped to Completed through the actual WooCommerce webhook,
covering a new guest customer, a returning registered customer, and a
multi-product order with a variation and a paid add-on. Also caught, during
this work, that n8n's Code nodes run in an external JS Task Runner process
where plain `fetch()` is unavailable — confirmed by a direct failing test,
then switched to `this.helpers.httpRequest(...)`.

**Twenty automations (ARR field, completed-order email).** Investigated
whether either automation could be built purely via API instead of a browser
click-through: confirmed structurally impossible by calling the actual
workflow-builder and mailbox-connect mutations directly (not just reading
schema introspection, which is filtered for API-key auth) — both rejected
API-key requests by design (`UserAuthGuard`/`WorkspaceAuthGuard` require a
real user session). Along the way, found and fixed several genuine
infrastructure bugs blocking Code-step workflows in this stack, by reading
`twenty-server`'s compiled source, container logs, and direct Postgres
inspection rather than guessing: `LOGIC_FUNCTION_TYPE` silently defaulting to
`DISABLED` outside `NODE_ENV=development`; the `twenty-worker` container
missing the volume mount for the compiled-function bundle `twenty-server`
writes (caused a worker-only `File not found` at runtime); and, once the
owner authored both workflows through Twenty's UI (the only path — no API
covers step-level wiring), a repeated pattern across many verification
sessions of owner-reported "it's fixed/done" claims that did **not** hold up
against direct DB inspection and a real live functional test — each one was
re-checked from scratch rather than taken on the report, which is how several
real wiring bugs were actually caught (an Update-Record step reading the
wrong source field producing `arr = amount` instead of `amount × 12`; a
Find-Customer step filtering on the wrong property, first causing an empty
match, later causing the workflow to fail outright; a Send-Email step with a
hardcoded test address instead of the customer's). Both workflows are now
**verified fully working end-to-end** with real live tests (not just green
UI checkmarks): the ARR workflow recomputes correctly on a real Opportunity
edit and does not re-trigger itself; the email workflow fires exactly once
per real synced order, correctly addressed and populated with real order
data. One pre-existing cosmetic-only defect remains and is disclosed rather
than hidden: the sent email's HTML MIME part is double-escaped in Mailhog's
HTML view (the plain-text part is correct). Full session-by-session
verification trail in `PROGRESS.md`'s category 6 notes; the final
confirmed-working state is in the last two entries there and in `README.md`
§5.

**Demonstration scenarios.** All seven of the assignment's required scenarios
(new customer, returning customer, multi-product + variation + add-on,
product-reuse-with-historical-price-preservation, duplicate webhook delivery,
fail-partway-then-retry, and both Twenty automations firing) were executed
for real against the live stack — real WP-CLI orders, real n8n executions,
real Twenty GraphQL queries as evidence — with the literal query/output pairs
captured in `demo-results.md`. Two small helper scripts
(`scripts/demo-replay-webhook.sh`, `scripts/demo-retrigger-webhook.sh`) were
written to engineer the duplicate-delivery and retry scenarios reproducibly;
both source secrets from `.env` at runtime rather than hardcoding any secret
value, and the replay script was dry-run tested before its first real send.
Scenario 7 (both automations) surfaced one real operational wrinkle, resolved
rather than worked around: WordPress's Action Scheduler queue (WP-Cron) is
pseudo-cron and didn't dispatch the completed-order webhook within a few
seconds on a quiet test instance, needing a manual
`wp cron event run action_scheduler_run_queue` nudge — a legitimate
run-what's-due action, not a fabricated trigger; documented in `README.md`
§9 as a disclosed limitation rather than silently worked around.

**Repository scaffolding, `.env.example`, Postgres init scripts, README, this
note (category 8 of this project's internal task breakdown).** Written by
Claude Code by directly reading `docker-compose.yml` /
`docker-compose.override.yml` to enumerate the actual environment variable
names in use (rather than guessing or copying a generic template), so
`.env.example` matches what the compose files actually reference,
variable-for-variable. The real `.env` file's secret *values* were never read,
printed, or copied into any generated file — only variable *names* were
extracted (e.g. via `grep -oE '^[A-Z_0-9]+='`), which is itself a guardrail
this project's own operating rules require.

## Current verification status

As of this note, every category (infrastructure, shop data, Twenty data
model, webhook gate, sync chain, both Twenty automations, and all 7 demo
scenarios) has been independently re-verified against live system state —
real database rows, real GraphQL queries, real functional tests — not taken
on any prior report's word, including this project's own earlier reports.
`README.md` no longer carries any `[PENDING]`/`[IN PROGRESS]` tags. The two
Twenty automations in particular (completed-order email, ARR calculation)
required a human click-through in Twenty's UI to author the workflow steps —
no API path exists for step-level wiring (confirmed by calling the real
workflow-builder mutations directly, not just reading schema introspection)
— and went through many rounds of "owner reports it's fixed" followed by a
from-scratch DB/functional re-check that frequently disagreed with the
report, before both were confirmed genuinely working end-to-end. Full
session-by-session trail in `PROGRESS.md`'s category 6/7 notes.

## Where AI output was corrected, not just accepted

- The n8n webhook path case-sensitivity bug above.
- The Twenty data model (Order/Product/Order Line Item) being reported
  "100% built" when it was actually missing entirely — caught by direct
  Postgres/GraphQL inspection instead of trusting the board, then rebuilt and
  re-verified with a live round trip.
- Owner-reported "I finished the ARR workflow" claims were checked against
  live `workflowRun` data and the stored step JSON each time rather than taken
  at face value — this repeatedly surfaced real gaps (unwired Code-step
  inputs, an Update Record step reading the wrong source field, dead orphaned
  steps causing a reported `FAILED` run) that a visual "it looks configured"
  check in the UI would have missed.
- `PROGRESS.md` itself records at least one case where a category's board
  entry was stale (claimed a blocker existed that had already been fixed in a
  prior session) — a reminder that even this project's own status tracking
  needs to be cross-checked against live system state (container env vars,
  actual DB rows), not taken as ground truth by default.
- A late-stage claim of "explicitly set the Send Email step's connected
  account" did not hold up in the stored config (still literally `""`) even
  after the email workflow was otherwise confirmed working — worth recording
  because the *functional* test passed regardless (Twenty falls back to the
  workspace's sole connected account when the field is blank), which is
  exactly the kind of gap between "the claim" and "the stored config" that
  only a direct DB read catches, not a working demo alone.
