#!/bin/bash
# =============================================================================
# run-migrations.sh — apply pending SQL migrations to the project's database.
#
# Called by deploy-app.sh after Patroni is healthy, before the app starts.
# Also runnable manually: bash scripts/ci/run-migrations.sh
#
# How it works:
#   1. Creates a `schema_migrations` tracking table (if not exists)
#   2. Lists all .sql files in migrations/ sorted by name
#   3. For each file not yet recorded in schema_migrations:
#      a. Runs it inside a transaction (BEGIN...COMMIT)
#      b. Records the filename + timestamp in schema_migrations
#      c. If it fails, the transaction rolls back and the script exits 1
#   4. Reports what was applied
#
# File naming convention: NNN_description.sql (e.g., 001_initial.sql,
# 002_add_users_table.sql). Files are applied in sort order.
#
# WHY plain SQL instead of Alembic?
# Alembic adds SQLAlchemy as a dependency, requires a Python migration
# environment, and is overkill for services that run 2-3 schema changes
# in their lifetime. Plain SQL files are transparent, reviewable, and
# run directly via psql — the same tool we already have in the Patroni
# container.
#
# Required env vars:
#   APP_DIR or REPO_ROOT  — path to the repo (to find migrations/)
#   POSTGRES_DB           — from project.config
#   SWARM_STACK           — from project.config (to find the Patroni leader)
# =============================================================================

set -euo pipefail

# Determine where the migrations directory is
if [ -n "${APP_DIR:-}" ]; then
    MIGRATIONS_DIR="${APP_DIR}/migrations"
    # Source project.config if not already loaded
    if [ -z "${POSTGRES_DB:-}" ] && [ -f "${APP_DIR}/project.config" ]; then
        set -a; source "${APP_DIR}/project.config"; set +a
    fi
elif [ -n "${REPO_ROOT:-}" ]; then
    MIGRATIONS_DIR="${REPO_ROOT}/migrations"
else
    MIGRATIONS_DIR="$(cd "$(dirname "$0")/../.." && pwd)/migrations"
fi

if [ ! -d "${MIGRATIONS_DIR}" ]; then
    echo "[migrations] no migrations/ directory found — skipping"
    exit 0
fi

MIGRATION_FILES=$(find "${MIGRATIONS_DIR}" -name '*.sql' -type f | sort)
if [ -z "${MIGRATION_FILES}" ]; then
    echo "[migrations] no .sql files in migrations/ — skipping"
    exit 0
fi

echo "[migrations] checking for pending migrations..."

# Find the Patroni leader container
find_leader() {
    # When running on the server (via CI), find the leader container
    for C in $(docker ps -qf "name=${SWARM_STACK}_patroni-rishi" 2>/dev/null); do
        IS_LEADER=$(docker exec "$C" psql -h 127.0.0.1 -U postgres -tAc "SELECT pg_is_in_recovery();" 2>/dev/null)
        if [ "$IS_LEADER" = "f" ]; then
            echo "$C"
            return 0
        fi
    done
    return 1
}

run_sql() {
    local sql="$1"
    LEADER=$(find_leader) || { echo "[migrations] FATAL: no Patroni leader found"; exit 1; }
    docker exec -i "$LEADER" psql -h 127.0.0.1 -U postgres -d "${POSTGRES_DB}" -v ON_ERROR_STOP=1 <<< "$sql"
}

run_sql_file() {
    local file="$1"
    LEADER=$(find_leader) || { echo "[migrations] FATAL: no Patroni leader found"; exit 1; }
    docker exec -i "$LEADER" psql -h 127.0.0.1 -U postgres -d "${POSTGRES_DB}" -v ON_ERROR_STOP=1 < "$file"
}

# Create the tracking table (idempotent)
run_sql "CREATE TABLE IF NOT EXISTS schema_migrations (
    filename VARCHAR(255) PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);"

# Get list of already-applied migrations
APPLIED=$(run_sql "SELECT filename FROM schema_migrations ORDER BY filename;" 2>/dev/null \
    | grep -E '^[0-9]' || true)

PENDING=0
while IFS= read -r FILE; do
    [ -z "$FILE" ] && continue
    BASENAME=$(basename "$FILE")

    # Skip if already applied
    if echo "$APPLIED" | grep -qF "$BASENAME"; then
        continue
    fi

    PENDING=$((PENDING + 1))
    echo "[migrations] applying: ${BASENAME}"

    # Run inside a transaction — if any statement fails, the whole
    # migration rolls back and we exit 1 (canary deploy catches this)
    LEADER=$(find_leader) || { echo "[migrations] FATAL: no Patroni leader found"; exit 1; }
    {
        echo "BEGIN;"
        cat "$FILE"
        echo "INSERT INTO schema_migrations (filename) VALUES ('${BASENAME}');"
        echo "COMMIT;"
    } | docker exec -i "$LEADER" psql -h 127.0.0.1 -U postgres -d "${POSTGRES_DB}" -v ON_ERROR_STOP=1 2>&1

    if [ $? -ne 0 ]; then
        echo "[migrations] FATAL: migration ${BASENAME} failed — transaction rolled back"
        exit 1
    fi

    echo "[migrations] ✓ ${BASENAME} applied"
done <<< "$MIGRATION_FILES"

if [ "$PENDING" -eq 0 ]; then
    echo "[migrations] all migrations already applied — nothing to do"
else
    echo "[migrations] ${PENDING} migration(s) applied successfully"
fi
