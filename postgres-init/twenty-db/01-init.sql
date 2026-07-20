-- Bootstrap-only init script for the twenty-db (postgres:16) container.
--
-- The official postgres image already creates the role and database named by
-- POSTGRES_USER / POSTGRES_PASSWORD / POSTGRES_DB (see docker-compose.yml) on
-- first boot, before anything in docker-entrypoint-initdb.d/ runs. Twenty CRM
-- manages its own schema via its own migrations on startup (twenty-server /
-- twenty-worker) — this script deliberately does NOT create any application
-- tables, Twenty objects, or data-model fields. The CRM data model (Person,
-- Product, Order, Order Line Item) is created through the Twenty UI/API, not
-- SQL — see README.md.
--
-- This file only ensures extensions Twenty commonly relies on are present
-- before Twenty's own migrations run. It only runs once, on first container
-- init with an empty data volume (standard postgres entrypoint behavior).

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gin;
