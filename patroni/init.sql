-- ---------------------------------------------------------------------------
-- init.sql — bootstrap infrastructure for the migration framework.
--
-- WHEN DOES THIS RUN?
-- Once, during the very first Patroni bootstrap (when a brand-new database
-- cluster is created). It's called by post_init.sh.
--
-- WHAT DOES IT CREATE?
-- ONLY the schema_migrations table — the tracking table that records
-- which migration files have been applied. All actual business schema
-- (counter table, etc.) lives in migrations/*.sql files.
--
-- WHY THE SEPARATION?
-- Having migrations/ as the SINGLE SOURCE OF TRUTH for schema means:
--   - You can see the complete database structure by reading migrations/
--   - New services start with migration 001 and build up
--   - Restoring from backup + re-running migrations brings schema up to date
-- ---------------------------------------------------------------------------

-- CREATE TABLE: makes a new table called "schema_migrations"
-- IF NOT EXISTS: don't crash if it already exists (safe to re-run)
--
-- This table has two columns:
--   filename:   the name of the migration file (e.g., "001_initial.sql")
--               VARCHAR(255) = a text string up to 255 characters
--               PRIMARY KEY = must be unique (can't apply the same migration twice)
--
--   applied_at: when the migration was applied
--               TIMESTAMPTZ = a date+time with timezone (e.g., "2026-04-12 10:30:00+00")
--               NOT NULL = must always have a value
--               DEFAULT NOW() = automatically set to the current time when a row is inserted
CREATE TABLE IF NOT EXISTS schema_migrations (
    filename VARCHAR(255) PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
