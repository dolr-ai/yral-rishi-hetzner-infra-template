-- Creates the counter table in counter_db.
-- This runs ONCE via post_init.sh on the primary after first bootstrap.

CREATE TABLE IF NOT EXISTS counter (
    id    INTEGER PRIMARY KEY,
    value BIGINT NOT NULL DEFAULT 0
);

-- The single counter row. Starts at 0.
-- First visitor triggers: UPDATE value = 0 + 1 → returns 1. Correct.
-- WHY BIGINT: can count up to 9.2 quintillion visitors. No overflow ever.
-- ON CONFLICT DO NOTHING makes this idempotent in case bootstrap retries.
INSERT INTO counter (id, value) VALUES (1, 0) ON CONFLICT (id) DO NOTHING;
