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
field decisions) collaboratively, then built by hand through Twenty's UI.
Design decisions documented in `README.md` §4 include the reasoning (e.g. why
email-lowercased for Person, why SKU for Product, why line items snapshot
name/price instead of live-referencing the Product).

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

## What has *not* been independently verified by a human yet

The sync chain into Twenty (upserts, dedup, retry behavior against real
Twenty API calls) and the two Twenty automations (completed-order email, ARR
calculation) were, as of this note, still in progress or not yet built — see
`PROGRESS.md` for current, honestly-reported percentages. Anything marked
`[PENDING]` in `README.md` reflects work not yet done, not work done but
undocumented.

## Where AI output was corrected, not just accepted

- The n8n webhook path case-sensitivity bug above.
- `PROGRESS.md` itself records at least one case where a category's board
  entry was stale (claimed a blocker existed that had already been fixed in a
  prior session) — a reminder that even this project's own status tracking
  needs to be cross-checked against live system state (container env vars,
  actual DB rows), not taken as ground truth by default.
