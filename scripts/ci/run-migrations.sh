#!/bin/bash
# =============================================================================
# run-migrations.sh — apply pending SQL migrations to the project's database.
#
# Called by deploy-app.sh BEFORE the new app container starts (expand-contract
# pattern). Also runnable manually or with --dry-run to preview.
#
# Usage:
#   APP_DIR=/path/to/repo bash scripts/ci/run-migrations.sh           # apply
#   APP_DIR=/path/to/repo bash scripts/ci/run-migrations.sh --dry-run # preview
#
# How it works:
#   1. Creates a `schema_migrations` tracking table (if not exists)
#   2. Lists all .sql files in migrations/ sorted by name
#   3. For each file not yet recorded in schema_migrations:
#      a. Sets lock_timeout = 5s (fail fast instead of blocking queries)
#      b. Runs it inside a transaction (BEGIN...COMMIT)
#      c. Records the filename + timestamp in schema_migrations
#      d. If it fails, the transaction rolls back and the script exits 1
#   4. Reports what was applied
#
# IMPORTANT — expand-contract discipline:
#   Migrations run while the OLD app code is still serving traffic.
#   Every migration must be backward-compatible with the current code.
#   See MIGRATIONS.md for the rules.
#
# Required env vars:
#   APP_DIR or REPO_ROOT  — path to the repo (to find migrations/)
#   POSTGRES_DB           — from project.config
#   SWARM_STACK           — from project.config (to find the Patroni leader)
# =============================================================================

set -euo pipefail

# Parse args
DRY_RUN="false"
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN="true" ;;
    esac
done

# Determine where the migrations directory is
if [ -n "${APP_DIR:-}" ]; then
    MIGRATIONS_DIR="${APP_DIR}/migrations"
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

# Only include forward migrations (*.sql but NOT *.down.sql)
MIGRATION_FILES=$(find "${MIGRATIONS_DIR}" -name '*.sql' ! -name '*.down.sql' -type f | sort)
if [ -z "${MIGRATION_FILES}" ]; then
    echo "[migrations] no .sql files in migrations/ — skipping"
    exit 0
fi

echo "[migrations] checking for pending migrations..."

# Migrations must run on the Swarm MANAGER only (rishi-1). Workers skip.
if ! docker node ls >/dev/null 2>&1; then
    echo "[migrations] not on the Swarm manager — skipping (applied by rishi-1)"
    exit 0
fi

# Find the Patroni leader container. On first deploy the cluster may still
# be bootstrapping (leader election takes ~30s), so we retry for up to 90s.
find_leader() {
    for C in $(docker ps -qf "name=${SWARM_STACK}_patroni-rishi" 2>/dev/null); do
        IS_LEADER=$(docker exec "$C" psql -h 127.0.0.1 -U postgres -tAc "SELECT pg_is_in_recovery();" 2>/dev/null)
        if [ "$IS_LEADER" = "f" ]; then
            echo "$C"
            return 0
        fi
    done
    return 1
}

wait_for_leader() {
    echo "[migrations] waiting for Patroni leader (up to 90s)..."
    for i in $(seq 1 30); do
        LEADER=$(find_leader 2>/dev/null) && { echo "[migrations] leader found after $((i*3))s"; return 0; }
        sleep 3
    done
    echo "[migrations] FATAL: no Patroni leader found after 90s"
    return 1
}

run_sql() {
    local sql="$1"
    LEADER=$(find_leader) || { echo "[migrations] FATAL: no Patroni leader found"; exit 1; }
    docker exec -i "$LEADER" psql -h 127.0.0.1 -U postgres -d "${POSTGRES_DB}" -v ON_ERROR_STOP=1 <<< "$sql"
}

# Wait for a leader before doing anything (first deploy may still be bootstrapping)
wait_for_leader || exit 1

# Create the tracking table (idempotent)
run_sql "CREATE TABLE IF NOT EXISTS schema_migrations (
    filename VARCHAR(255) PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);"

# Get already-applied migrations (-tA = tuples-only, unaligned)
LEADER=$(find_leader) || { echo "[migrations] FATAL: no Patroni leader found"; exit 1; }
APPLIED=$(docker exec -i "$LEADER" psql -h 127.0.0.1 -U postgres -d "${POSTGRES_DB}" -tA \
    -c "SELECT filename FROM schema_migrations ORDER BY filename;" 2>/dev/null || true)

PENDING=0
while IFS= read -r FILE; do
    [ -z "$FILE" ] && continue
    BASENAME=$(basename "$FILE")

    # Skip if already applied
    if echo "$APPLIED" | grep -qF "$BASENAME"; then
        continue
    fi

    PENDING=$((PENDING + 1))

    if [ "${DRY_RUN}" = "true" ]; then
        echo "[migrations] WOULD APPLY: ${BASENAME}"
        continue
    fi

    echo "[migrations] applying: ${BASENAME}"

    # Run inside a transaction with a 5-second lock timeout.
    # If the migration needs an exclusive lock (ALTER TABLE) and can't
    # acquire it within 5s (because a query is running), the migration
    # fails fast instead of blocking all queries. The deploy halts and
    # the canary catches it.
    LEADER=$(find_leader) || { echo "[migrations] FATAL: no Patroni leader found"; exit 1; }
    {
        echo "BEGIN;"
        echo "SET lock_timeout = '5s';"
        cat "$FILE"
        echo "INSERT INTO schema_migrations (filename) VALUES ('${BASENAME}');"
        echo "COMMIT;"
    } | docker exec -i "$LEADER" psql -h 127.0.0.1 -U postgres -d "${POSTGRES_DB}" -v ON_ERROR_STOP=1 2>&1

    if [ $? -ne 0 ]; then
        echo "[migrations] FATAL: ${BASENAME} failed — transaction rolled back, deploy halted"
        exit 1
    fi

    echo "[migrations] ✓ ${BASENAME} applied"
done <<< "$MIGRATION_FILES"

if [ "${DRY_RUN}" = "true" ]; then
    if [ "$PENDING" -eq 0 ]; then
        echo "[migrations] dry-run: all migrations already applied"
    else
        echo "[migrations] dry-run: ${PENDING} migration(s) would be applied"
    fi
elif [ "$PENDING" -eq 0 ]; then
    echo "[migrations] all migrations already applied — nothing to do"
else
    echo "[migrations] ${PENDING} migration(s) applied successfully"
fi
