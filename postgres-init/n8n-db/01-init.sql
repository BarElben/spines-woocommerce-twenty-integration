-- Bootstrap-only init script for the n8n-db (postgres:16) container.
--
-- The official postgres image already creates the role and database named by
-- POSTGRES_USER / POSTGRES_PASSWORD / POSTGRES_DB (see docker-compose.yml) on
-- first boot, before anything in docker-entrypoint-initdb.d/ runs. n8n manages
-- its own schema via its internal TypeORM migrations on startup — this script
-- deliberately does NOT create any application tables.
--
-- This file only adds extensions/settings that are safe to have available and
-- that n8n or future workflow nodes may want, without prescribing schema n8n
-- owns itself. It only runs once, on first container init with an empty
-- data volume (standard postgres entrypoint behavior).

-- Useful for case-insensitive / fuzzy matching if a future workflow node ever
-- needs it (e.g. matching against text columns). Harmless if unused.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- UUID generation helper, commonly wanted alongside Postgres-backed apps.
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
