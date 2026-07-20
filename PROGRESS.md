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
| 8 | Repo + README + submission                 | 8%     | 15%    | seed script + compose exist |

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
