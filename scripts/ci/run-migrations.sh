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
# IMPORTANT — expand-contract discipline:
#   Migrations run while the OLD app code is still serving traffic.
#   Every migration must be backward-compatible with the current code.
#   See MIGRATIONS.md for the rules.
# =============================================================================

set -euo pipefail

DRY_RUN="false"
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN="true" ;;
    esac
done

# Determine migrations directory
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

MIGRATION_FILES=$(find "${MIGRATIONS_DIR}" -name '*.sql' ! -name '*.down.sql' -type f | sort)
if [ -z "${MIGRATION_FILES}" ]; then
    echo "[migrations] no .sql files in migrations/ — skipping"
    exit 0
fi

echo "[migrations] checking for pending migrations..."

# Only run on the Swarm MANAGER (rishi-1). Workers auto-skip.
if ! docker node ls >/dev/null 2>&1; then
    echo "[migrations] not on the Swarm manager — skipping (applied by rishi-1)"
    exit 0
fi

# Find ANY local Patroni container to use as a psql client. We connect
# THROUGH HAProxy (which routes to the leader) rather than trying to
# docker-exec into the leader directly — because the leader might be on
# rishi-2 or rishi-3, and docker ps only shows local containers.
HAPROXY_HOST="haproxy-rishi-1"

find_local_patroni() {
    docker ps -qf "name=${SWARM_STACK}_patroni-rishi" 2>/dev/null | head -1
}

wait_for_db() {
    echo "[migrations] waiting for database via HAProxy (up to 120s)..."
    for i in $(seq 1 40); do
        LOCAL_C=$(find_local_patroni)
        if [ -n "$LOCAL_C" ]; then
            PG_PASS=$(docker exec "$LOCAL_C" cat /run/secrets/postgres_password 2>/dev/null || echo "")
            if docker exec -e PGPASSWORD="$PG_PASS" "$LOCAL_C" psql -h "${HAPROXY_HOST}" -U postgres -d "${POSTGRES_DB}" -tAc "SELECT 1;" >/dev/null 2>&1; then
                echo "[migrations] database reachable via HAProxy after $((i*3))s"
                return 0
            fi
        fi
        sleep 3
    done
    echo "[migrations] FATAL: database not reachable via HAProxy after 120s"
    return 1
}

run_sql() {
    local sql="$1"
    LOCAL_C=$(find_local_patroni)
    [ -z "$LOCAL_C" ] && { echo "[migrations] FATAL: no local Patroni container"; exit 1; }
    # HAProxy is a remote connection → md5 auth → needs PGPASSWORD.
    # Read it from the Swarm secret mounted inside the Patroni container.
    docker exec -i -e PGPASSWORD="$(docker exec "$LOCAL_C" cat /run/secrets/postgres_password 2>/dev/null)" \
        "$LOCAL_C" psql -h "${HAPROXY_HOST}" -U postgres -d "${POSTGRES_DB}" -v ON_ERROR_STOP=1 <<< "$sql"
}

# Wait for DB to be reachable (first deploy: Patroni bootstrapping)
wait_for_db || exit 1

# Create the tracking table (idempotent)
run_sql "CREATE TABLE IF NOT EXISTS schema_migrations (
    filename VARCHAR(255) PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);"

# Get already-applied migrations
LOCAL_C=$(find_local_patroni)
PG_PASS=$(docker exec "$LOCAL_C" cat /run/secrets/postgres_password 2>/dev/null || echo "")
APPLIED=$(docker exec -i -e PGPASSWORD="$PG_PASS" "$LOCAL_C" psql -h "${HAPROXY_HOST}" -U postgres -d "${POSTGRES_DB}" -tA \
    -c "SELECT filename FROM schema_migrations ORDER BY filename;" 2>/dev/null || true)

PENDING=0
while IFS= read -r FILE; do
    [ -z "$FILE" ] && continue
    BASENAME=$(basename "$FILE")

    if echo "$APPLIED" | grep -qF "$BASENAME"; then
        continue
    fi

    PENDING=$((PENDING + 1))

    if [ "${DRY_RUN}" = "true" ]; then
        echo "[migrations] WOULD APPLY: ${BASENAME}"
        continue
    fi

    echo "[migrations] applying: ${BASENAME}"

    LOCAL_C=$(find_local_patroni)
    PG_PASS=$(docker exec "$LOCAL_C" cat /run/secrets/postgres_password 2>/dev/null || echo "")
    {
        echo "BEGIN;"
        echo "SET lock_timeout = '5s';"
        cat "$FILE"
        echo "INSERT INTO schema_migrations (filename) VALUES ('${BASENAME}');"
        echo "COMMIT;"
    } | docker exec -i -e PGPASSWORD="$PG_PASS" "$LOCAL_C" psql -h "${HAPROXY_HOST}" -U postgres -d "${POSTGRES_DB}" -v ON_ERROR_STOP=1 2>&1

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
