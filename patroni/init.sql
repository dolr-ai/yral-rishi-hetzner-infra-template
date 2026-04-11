-- Bootstrap infrastructure for the migration framework.
-- This runs ONCE via post_init.sh on the primary after first Patroni bootstrap.
--
-- IMPORTANT: this file creates ONLY the schema_migrations tracking table.
-- All business-logic schema (tables, indexes, etc.) lives in migrations/*.sql
-- and is applied by scripts/ci/run-migrations.sh. This separation makes
-- migrations/ the single source of truth for the database schema.

CREATE TABLE IF NOT EXISTS schema_migrations (
    filename VARCHAR(255) PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
