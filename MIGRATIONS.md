# Database migrations

This template uses plain SQL migration files for schema changes. No ORM,
no Alembic, no magic — just numbered `.sql` files that run in order via
`psql`.

## How it works

```
migrations/
├── 001_initial.sql              ← creates the counter table
├── 002_add_email_column.sql     ← adds a column (example)
└── 003_add_notifications.sql    ← adds a new table (example)
```

Each file runs inside a `BEGIN...COMMIT` transaction. If any statement
fails, the entire migration rolls back. A `schema_migrations` table
tracks which files have been applied.

Migrations run **before** the new app container starts (not after). This
means the old code is still running when the migration executes, so the
migration must be backward-compatible with the current code.

## The golden rule: expand-contract

Every schema change follows this pattern:

### Deploy 1 — Expand (add the new thing)

The old code doesn't use it; the new code will.

```sql
-- 002_add_email.sql — SAFE: nullable column with default
ALTER TABLE users ADD COLUMN IF NOT EXISTS email VARCHAR(255) DEFAULT NULL;
```

```sql
-- 003_add_notifications.sql — SAFE: new table, old code ignores it
CREATE TABLE IF NOT EXISTS notifications (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id),
    message TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
```

### Deploy 2 — Contract (remove the old thing)

Only after ALL servers run the new code that no longer uses the old column:

```sql
-- 004_drop_old_name.sql — SAFE: no code references old_name anymore
ALTER TABLE users DROP COLUMN IF EXISTS old_name;
```

## What you must NEVER do in a single migration

| Dangerous change | Why it breaks | Safe alternative |
|---|---|---|
| `ALTER TABLE users RENAME COLUMN name TO full_name` | Old code still uses `name` → crashes | Add `full_name`, copy data, deploy code that uses `full_name`, then drop `name` |
| `ALTER TABLE users ALTER COLUMN age TYPE BIGINT` | Implicit cast may fail on existing rows | Add `age_v2 BIGINT`, backfill, deploy, drop `age` |
| `ALTER TABLE users ADD COLUMN email VARCHAR NOT NULL` | Existing rows have no value → constraint violation | Add as `DEFAULT NULL` first, backfill, then `ALTER COLUMN SET NOT NULL` |
| `DROP TABLE sessions` | Old code still queries it → crashes | Deploy code that stops using it first, then drop |

## Writing a migration

1. Create a new file: `migrations/NNN_description.sql`
   ```bash
   touch migrations/002_add_email.sql
   ```

2. Write idempotent SQL (use `IF NOT EXISTS`, `IF EXISTS`, `ON CONFLICT`):
   ```sql
   -- 002_add_email.sql
   ALTER TABLE users ADD COLUMN IF NOT EXISTS email VARCHAR(255) DEFAULT NULL;
   CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
   ```

3. Test locally:
   ```bash
   bash local/setup.sh
   APP_DIR=$(pwd) bash scripts/ci/run-migrations.sh
   ```

4. Preview what CI will apply (without executing):
   ```bash
   APP_DIR=$(pwd) bash scripts/ci/run-migrations.sh --dry-run
   ```

5. Commit + push. CI applies the migration before starting the new app.

## How migrations run during deploy

```
CI pushes new code + new migration file
  ↓
SCP files to rishi-1 (including migrations/)
  ↓
run-migrations.sh applies 002_add_email.sql    ← OLD code still running
  ↓
docker compose up -d (NEW code starts)          ← NEW code finds the column
  ↓
health check + canary verification
  ↓
same on rishi-2
```

If the migration fails: the transaction rolls back, the deploy halts,
rishi-2 stays on the old code, and Cloudflare DNS round-robin keeps
serving via rishi-2.

## Safety features

- **lock_timeout = 5s**: if a migration needs an exclusive lock (ALTER TABLE)
  and can't get it within 5 seconds, it fails fast instead of blocking queries.
- **Transaction wrapping**: every migration runs in BEGIN...COMMIT. Failure
  rolls back the entire migration — no partial schema state.
- **Canary deploy**: migrations run on rishi-1 first. If they fail, rishi-2
  is never touched.
- **Swarm manager only**: migrations only run on rishi-1 (the Swarm manager).
  rishi-2's deploy skips migrations automatically.

## Rolling back a migration

**Primary method:** restore from backup.
```bash
bash scripts/restore-from-backup.sh --latest
```

**Optional:** write a corresponding `.down.sql` file:
```
migrations/002_add_email.sql       ← forward (applied by CI)
migrations/002_add_email.down.sql  ← reverse (applied manually)
```

Down files are not applied automatically — they're a manual safety net.

## Fresh cluster bootstrap

When a new Patroni cluster bootstraps (first deploy or after a full reset),
`patroni/post_init.sh` applies ALL migration files in order. This brings
a fresh database to the latest schema without needing multiple deploys.
The `schema_migrations` table records every applied file so subsequent
deploys don't re-apply them.
