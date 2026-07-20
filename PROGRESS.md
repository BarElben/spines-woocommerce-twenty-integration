# Progress Board — single source of truth
Every agent MUST update its category's percentage and notes after each work session.
Overall % = weighted sum. Be honest; verified-working only counts.

| # | Category                                   | Weight | Done % | Notes |
|---|--------------------------------------------|--------|--------|-------|
| 1 | Infrastructure (server, compose, HTTPS)    | 20%    | 100%   | verified |
| 2 | Shop + test data (products, orders, seed)  | 15%    | 100%   | orders 30-32 staged |
| 3 | Twenty data model + API access             | 10%    | 100%   | built via UI |
| 4 | Webhook + security gate                    | 10%    | 100%   | verified — see notes below |
| 5 | Sync chain (upserts, dedup, retry)         | 20%    | 5%     | designed, not built; TWENTY_API_KEY now present in .env/n8n so unblocked |
| 6 | Twenty automations (email + ARR)           | 10%    | 0%     | |
| 7 | Demonstration (7 scenarios)                | 7%     | 0%     | |
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
