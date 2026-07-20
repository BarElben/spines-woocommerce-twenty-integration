# Home Assignment – Tech Lead (Spines)

Objective: whenever a WooCommerce order reaches Completed, an n8n workflow syncs
the customer, order, products, quantities, prices, variations, and add-ons into
a self-hosted Twenty CRM.

Infrastructure: WordPress+WooCommerce on any host allowing plugins. Everything
else on a Linux cloud server via Docker Compose: reverse proxy, n8n (PostgreSQL
database), self-hosted Twenty CRM + dependencies. Only required ports public;
SSH restricted to owner IP; databases not publicly exposed; data persists across
restarts; no secrets in repo; all web traffic through the reverse proxy; public
interfaces over HTTPS (paid domain not required). Document the approach.

WooCommerce: test customers and products (name, SKU, price, description,
variations or paid add-ons affecting final price). Test orders covering: new
customer, returning customer, multiple products in one order, variations and
add-ons, a product appearing in more than one order. Webhooks to n8n with a
webhook secret. Only completed orders processed.

Integration: n8n workflow syncs completed orders into Twenty via its API.
Design + document the data model: records, relationships, unique identifiers
for duplicate prevention, registered/guest matching, partial-failure and retry
handling. Must preserve historical purchase data (later name/price changes do
not alter past orders), reuse products, and correctly handle: returning
customer, same product in multiple orders, multi-product orders, variations and
add-ons, same webhook delivered twice, retry after partial failure — all with
zero duplicate records.

Twenty automations: (1) on order finishing sync — formatted email with customer
info, Woo order number, total, products, quantities, amounts,
variations/add-ons, to record owner or configurable test recipient.
(2) ARR field on Opportunity: JS Code action inside Twenty (not n8n),
ARR = Amount × 12 on create or amount change; handles empty/zero; must not
re-trigger itself.

Demonstration: new customer order; same customer again; multi-product+add-ons
order; previously purchased product in a new order; same webhook twice; a run
failing partway then succeeding on retry; both Twenty workflows running.

Deliverables: repo with Docker Compose + reverse proxy config, .env.example
(no secrets), exported n8n workflow, PostgreSQL init scripts, README (setup,
architecture + data model, duplicate-prevention + retry approach, limitations
and assumptions). Note AI tools used, for what, and how output was validated.
Submit to nir@spines.com and confirm receipt.
