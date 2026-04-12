#!/bin/bash
# ---------------------------------------------------------------------------
# run-migrations.sh — apply pending SQL migrations to the project's database.
#
# WHAT IS A MIGRATION?
# A migration is a SQL file (like 001_create_counter.sql) that changes the
# database schema (tables, columns, indexes). Migrations are numbered so they
# run in order, and each one only runs ONCE (tracked in a schema_migrations table).
#
# WHEN DOES THIS RUN?
# Called by deploy-app.sh BEFORE the new app container starts. This ensures
# the database schema is updated BEFORE the new code tries to use it.
# This is the "expand-contract" pattern for zero-downtime schema changes.
#
# HOW DOES IT WORK?
# 1. Finds a local Patroni container (which has psql installed)
# 2. Connects to the database VIA HAPROXY (which routes to the leader)
# 3. Checks which migrations have already been applied (schema_migrations table)
# 4. Applies any new migrations in order, each wrapped in a transaction
#
# USAGE:
#   APP_DIR=/path/to/repo bash scripts/ci/run-migrations.sh           # apply
#   APP_DIR=/path/to/repo bash scripts/ci/run-migrations.sh --dry-run # preview
#
# IMPORTANT — expand-contract discipline:
#   Migrations run while the OLD app code is still serving traffic.
#   Every migration must be backward-compatible with the current code.
#   See MIGRATIONS.md for the rules.
# ---------------------------------------------------------------------------

# "set -euo pipefail" = strict error handling:
#   -e: stop on any error
#   -u: treat unset variables as errors (catch typos)
#   -o pipefail: if any command in a pipe fails, the whole pipe fails
set -euo pipefail

# Check if --dry-run was passed (preview mode: show what WOULD be applied)
DRY_RUN="false"
# Loop through all command-line arguments
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN="true" ;;
    esac
done

# ----- Determine where the migrations/ directory is -----
# This script can be called from different contexts:
#   - From deploy-app.sh: APP_DIR is set
#   - From manual testing: REPO_ROOT might be set
#   - Standalone: figure it out from the script's own location
if [ -n "${APP_DIR:-}" ]; then
    # Called by deploy-app.sh — migrations are in the app directory
    MIGRATIONS_DIR="${APP_DIR}/migrations"
    # If POSTGRES_DB isn't already set, load it from project.config
    if [ -z "${POSTGRES_DB:-}" ] && [ -f "${APP_DIR}/project.config" ]; then
        # Source project.config to get POSTGRES_DB, SWARM_STACK, etc.
        set -a; source "${APP_DIR}/project.config"; set +a
    fi
elif [ -n "${REPO_ROOT:-}" ]; then
    # Manual testing with REPO_ROOT set
    MIGRATIONS_DIR="${REPO_ROOT}/migrations"
else
    # Standalone — figure out the repo root from this script's location
    # "$(dirname "$0")" = the directory containing this script (scripts/ci/)
    # "../.." = go up two levels to the repo root
    MIGRATIONS_DIR="$(cd "$(dirname "$0")/../.." && pwd)/migrations"
fi

# If there's no migrations/ directory at all, there's nothing to do
if [ ! -d "${MIGRATIONS_DIR}" ]; then
    echo "[migrations] no migrations/ directory found — skipping"
    exit 0
fi

# Find all .sql files in the migrations/ directory, sorted by filename.
# "! -name '*.down.sql'" excludes rollback migration files (we only run "up" migrations).
# "sort" ensures migrations run in order (001_xxx.sql before 002_xxx.sql).
MIGRATION_FILES=$(find "${MIGRATIONS_DIR}" -name '*.sql' ! -name '*.down.sql' -type f | sort)
# If there are no SQL files, nothing to do
if [ -z "${MIGRATION_FILES}" ]; then
    echo "[migrations] no .sql files in migrations/ — skipping"
    exit 0
fi

echo "[migrations] checking for pending migrations..."

# ----- Only run on the Swarm manager (rishi-1) -----
# "docker node ls" only works on the Swarm manager. If it fails, we're on
# a worker node. Workers skip migrations — the manager handles it for the
# whole cluster (all servers share the same database via HAProxy).
if ! docker node ls >/dev/null 2>&1; then
    echo "[migrations] not on the Swarm manager — skipping (applied by rishi-1)"
    exit 0
fi

# ----- Find a Patroni container to use as a psql client -----
# We need a container with psql installed. Patroni containers have it.
# We connect THROUGH HAProxy (not directly to a Patroni node) because:
#   - HAProxy automatically routes to the LEADER (the only node that accepts writes)
#   - The leader might be on rishi-2 or rishi-3, and docker ps only shows LOCAL containers
HAPROXY_HOST="haproxy-rishi-1"

# Helper function: find the first local Patroni container's ID.
# "docker ps -qf" lists container IDs filtered by name.
# "head -1" takes the first one (there should only be one per server).
find_local_patroni() {
    docker ps -qf "name=${SWARM_STACK}_patroni-rishi" 2>/dev/null | head -1
}

# Helper function: wait up to 120 seconds for the database to be reachable.
# On the very first deploy, Patroni might still be bootstrapping the database.
wait_for_db() {
    echo "[migrations] waiting for database via HAProxy (up to 120s)..."
    # Try 40 times with 3-second sleeps = 120 seconds max
    for i in $(seq 1 40); do
        # Find a local Patroni container
        LOCAL_C=$(find_local_patroni)
        if [ -n "$LOCAL_C" ]; then
            # Read the postgres password from the Swarm secret inside the container.
            # It's mounted at /run/secrets/postgres_password.
            PG_PASS=$(docker exec "$LOCAL_C" cat /run/secrets/postgres_password 2>/dev/null || echo "")
            # Try to run "SELECT 1;" against the database via HAProxy.
            # If this succeeds, the database is up and reachable.
            # -tA: tuples-only, unAligned (just the raw value, no formatting)
            if docker exec -e PGPASSWORD="$PG_PASS" "$LOCAL_C" psql -h "${HAPROXY_HOST}" -U postgres -d "${POSTGRES_DB}" -tAc "SELECT 1;" >/dev/null 2>&1; then
                echo "[migrations] database reachable via HAProxy after $((i*3))s"
                return 0
            fi
        fi
        # Database not ready yet — wait 3 seconds and try again
        sleep 3
    done
    echo "[migrations] FATAL: database not reachable via HAProxy after 120s"
    return 1
}

# Helper function: execute a SQL statement against the database.
# Takes one argument: the SQL to execute.
run_sql() {
    local sql="$1"
    # Find a local Patroni container (re-find each time in case it restarted)
    LOCAL_C=$(find_local_patroni)
    # If no container found, we can't run SQL — fatal error
    [ -z "$LOCAL_C" ] && { echo "[migrations] FATAL: no local Patroni container"; exit 1; }
    # Run the SQL via docker exec → psql.
    # HAProxy is a remote connection → requires md5 password authentication →
    # needs PGPASSWORD. We read it from the Swarm secret inside the container.
    # "-i" = read from stdin (the SQL is piped in via <<<).
    # "-v ON_ERROR_STOP=1" = stop on the first SQL error (don't silently continue).
    docker exec -i -e PGPASSWORD="$(docker exec "$LOCAL_C" cat /run/secrets/postgres_password 2>/dev/null)" \
        "$LOCAL_C" psql -h "${HAPROXY_HOST}" -U postgres -d "${POSTGRES_DB}" -v ON_ERROR_STOP=1 <<< "$sql"
}

# Wait for the database to be reachable before trying to run migrations
wait_for_db || exit 1

# ----- Create the migration tracking table (if it doesn't exist) -----
# This table records which migrations have already been applied.
# "IF NOT EXISTS" makes this safe to run multiple times (idempotent).
# Columns:
#   filename: the migration file name (e.g., "001_create_counter.sql") — primary key
#   applied_at: when the migration was applied (auto-set to NOW())
run_sql "CREATE TABLE IF NOT EXISTS schema_migrations (
    filename VARCHAR(255) PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);"

# ----- Get the list of already-applied migrations -----
# Query the schema_migrations table for all filenames that have been applied.
LOCAL_C=$(find_local_patroni)
PG_PASS=$(docker exec "$LOCAL_C" cat /run/secrets/postgres_password 2>/dev/null || echo "")
# "-tA" = tuples only, unaligned (just the filename, one per line, no table formatting)
APPLIED=$(docker exec -i -e PGPASSWORD="$PG_PASS" "$LOCAL_C" psql -h "${HAPROXY_HOST}" -U postgres -d "${POSTGRES_DB}" -tA \
    -c "SELECT filename FROM schema_migrations ORDER BY filename;" 2>/dev/null || true)

# ----- Apply pending migrations -----
PENDING=0
# Loop through each migration file (already sorted by name)
while IFS= read -r FILE; do
    # Skip empty lines
    [ -z "$FILE" ] && continue
    # Extract just the filename (e.g., "001_create_counter.sql" from the full path)
    BASENAME=$(basename "$FILE")

    # Check if this migration was already applied.
    # "grep -qF" = quiet, Fixed string (exact match, not regex).
    if echo "$APPLIED" | grep -qF "$BASENAME"; then
        # Already applied — skip it
        continue
    fi

    # This migration hasn't been applied yet
    PENDING=$((PENDING + 1))

    # In dry-run mode, just print what WOULD be applied (don't actually run it)
    if [ "${DRY_RUN}" = "true" ]; then
        echo "[migrations] WOULD APPLY: ${BASENAME}"
        continue
    fi

    echo "[migrations] applying: ${BASENAME}"

    # Re-find the Patroni container and password (in case of restart during migration)
    LOCAL_C=$(find_local_patroni)
    PG_PASS=$(docker exec "$LOCAL_C" cat /run/secrets/postgres_password 2>/dev/null || echo "")
    # Run the migration inside a TRANSACTION.
    # A transaction means: either ALL the SQL succeeds, or NONE of it takes effect.
    # If the migration has a bug, the database stays unchanged (no partial damage).
    {
        echo "BEGIN;"                   # Start the transaction
        echo "SET lock_timeout = '5s';" # Don't wait more than 5s for table locks
                                        # (prevents blocking other queries for too long)
        cat "$FILE"                     # The actual migration SQL
        # Record this migration as applied (inside the SAME transaction,
        # so if the migration fails, this insert is also rolled back)
        echo "INSERT INTO schema_migrations (filename) VALUES ('${BASENAME}');"
        echo "COMMIT;"                  # Commit the transaction (make changes permanent)
    } | docker exec -i -e PGPASSWORD="$PG_PASS" "$LOCAL_C" psql -h "${HAPROXY_HOST}" -U postgres -d "${POSTGRES_DB}" -v ON_ERROR_STOP=1 2>&1

    # Check if the above command failed
    if [ $? -ne 0 ]; then
        # Migration failed — the transaction was automatically rolled back,
        # so the database is unchanged. Exit with error to halt the deploy.
        echo "[migrations] FATAL: ${BASENAME} failed — transaction rolled back, deploy halted"
        exit 1
    fi

    echo "[migrations] ✓ ${BASENAME} applied"
# "<<< "$MIGRATION_FILES"" feeds the file list as stdin to the while loop
done <<< "$MIGRATION_FILES"

# ----- Print summary -----
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
