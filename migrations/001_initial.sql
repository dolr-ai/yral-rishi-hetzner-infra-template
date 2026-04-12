-- ---------------------------------------------------------------------------
-- Migration 001: initial schema — creates the counter table.
--
-- WHAT IS A MIGRATION?
-- A migration is a SQL file that changes the database structure (schema).
-- Migrations are numbered (001, 002, 003...) and run IN ORDER. Once a
-- migration has been applied, it's never run again (tracked in the
-- schema_migrations table).
--
-- WHAT IS THIS FILE?
-- This is the FIRST migration — it creates the counter table that the
-- template's default app uses. When you create a new service from this
-- template, you'll replace this with your own schema.
--
-- WHY "IF NOT EXISTS" AND "ON CONFLICT DO NOTHING"?
-- These make the migration IDEMPOTENT (safe to run multiple times).
-- If the table/row already exists, the command does nothing instead of
-- crashing. This is important because:
--   1. During a restore-from-backup, the migration might run again
--   2. During a Patroni re-bootstrap, it might run again
--   3. If a deploy retries, it might run again
--
-- Lines starting with -- are COMMENTS (ignored by PostgreSQL).
-- ---------------------------------------------------------------------------

-- CREATE TABLE: creates a new table in the database.
-- IF NOT EXISTS: don't crash if the table already exists (idempotent).
--
-- The "counter" table has two columns:
--   id:    a unique number identifying each counter (we only use id=1)
--          INTEGER = a whole number (no decimals)
--          PRIMARY KEY = must be unique, and PostgreSQL indexes it for fast lookups
--
--   value: the current counter value
--          BIGINT = a VERY large whole number (up to 9.2 quintillion)
--          NOT NULL = this column can never be empty (must always have a value)
--          DEFAULT 0 = if you insert a row without specifying a value, it starts at 0
CREATE TABLE IF NOT EXISTS counter (
    id    INTEGER PRIMARY KEY,
    value BIGINT NOT NULL DEFAULT 0
);

-- INSERT a starting row: counter #1, value = 0.
-- This is the row that get_next_count() increments on every web request.
--
-- ON CONFLICT (id) DO NOTHING:
--   If a row with id=1 already exists, do nothing (don't crash, don't overwrite).
--   This makes it safe to run this migration multiple times.
INSERT INTO counter (id, value) VALUES (1, 0) ON CONFLICT (id) DO NOTHING;
