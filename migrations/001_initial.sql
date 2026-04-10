-- Migration 001: initial schema (same as patroni/init.sql).
--
-- This file exists so the migration framework has a baseline. New services
-- forked from the template start here. The counter table is the template's
-- default business logic — replace it with your own schema.

CREATE TABLE IF NOT EXISTS counter (
    id    INTEGER PRIMARY KEY,
    value BIGINT NOT NULL DEFAULT 0
);

INSERT INTO counter (id, value) VALUES (1, 0) ON CONFLICT (id) DO NOTHING;
