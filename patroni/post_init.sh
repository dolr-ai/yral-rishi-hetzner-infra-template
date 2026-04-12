#!/bin/bash
# ---------------------------------------------------------------------------
# post_init.sh — runs ONCE after the PostgreSQL cluster is first created.
#
# WHEN DOES THIS RUN?
# Only once, on the FIRST server that becomes the leader. Patroni calls
# this script after it runs "initdb" (which creates a bare, empty database).
# Replicas get all this data automatically via streaming replication —
# they do NOT run this script.
#
# WHAT DOES IT DO? (5 steps)
#   1. Sets the postgres superuser's password (initdb leaves it blank)
#   2. Creates the "replicator" user (used by replicas to stream data)
#   3. Creates the "rewind_user" (used by pg_rewind for re-joining after failover)
#   4. Creates the project's database (e.g., "rishi_hetzner_infra_template_db")
#   5. Runs all SQL migration files to create the business schema
#
# IDEMPOTENCY:
# Every statement uses "IF NOT EXISTS" or "DO...EXCEPTION WHEN duplicate_object"
# so this script is SAFE TO RE-RUN. If Patroni re-bootstraps (e.g., after an
# etcd state loss), it calls this script again. Without idempotency, the
# "CREATE USER replicator" would crash with "already exists" and the cluster
# would get stuck in an unrecoverable state. This was the #1 cause of
# "database corruption" in earlier versions of this template.
#
# HOW IS IT CALLED?
# Patroni passes a connection string as the first argument ($1), like:
#   "host=/tmp port=5432 user=postgres dbname=postgres"
# We use this to connect to the local PostgreSQL instance.
# ---------------------------------------------------------------------------

# Stop on any error
set -e

# $1 is the first argument passed to this script (the connection string)
CONN="$1"

# ----- Read passwords from Docker Swarm secrets -----
# Swarm mounts secret files at /run/secrets/<name> inside the container.
# "cat" reads the file content into a variable.
if [ -f /run/secrets/postgres_password ]; then
    POSTGRES_PASSWORD=$(cat /run/secrets/postgres_password)
fi
if [ -f /run/secrets/replication_password ]; then
    REPLICATION_PASSWORD=$(cat /run/secrets/replication_password)
fi

# Validate that we have both passwords
# "-z" means "is empty?" — if either is empty, we can't continue
if [ -z "$POSTGRES_PASSWORD" ] || [ -z "$REPLICATION_PASSWORD" ]; then
    echo "FATAL: POSTGRES_PASSWORD or REPLICATION_PASSWORD not set"
    exit 1
fi

# Validate that we know which database to create
# POSTGRES_DB comes from project.config via the Swarm stack's environment block
if [ -z "$POSTGRES_DB" ]; then
    echo "FATAL: POSTGRES_DB env var not set (should come from project.config via stack.yml)"
    exit 1
fi

echo "==> Running post-bootstrap initialization (idempotent)..."

# ----- STEP 1: Set the postgres superuser password -----
# "ALTER USER" changes an existing user's properties.
# initdb creates the postgres user WITHOUT a password. We need a password
# for remote connections (the app connects via HAProxy over the network).
# ALTER is always safe to re-run — it just overwrites the password.
psql "$CONN" -c "ALTER USER postgres WITH PASSWORD '${POSTGRES_PASSWORD}';"
echo "==> Set postgres password"

# ----- STEP 2: Create the replicator user -----
# Replicas use this user to stream data from the leader.
# "WITH REPLICATION" gives the user permission to start streaming replication.
#
# "DO $$ ... EXCEPTION WHEN duplicate_object" is PL/pgSQL (PostgreSQL's
# procedural language). It means: "try to CREATE USER; if the user already
# exists (duplicate_object error), catch the error and ALTER instead."
# This makes it idempotent — safe to run multiple times.
psql "$CONN" <<SQL
DO \$\$
BEGIN
    CREATE USER replicator WITH REPLICATION PASSWORD '${REPLICATION_PASSWORD}';
    RAISE NOTICE 'Created replicator user';
EXCEPTION WHEN duplicate_object THEN
    ALTER USER replicator WITH PASSWORD '${REPLICATION_PASSWORD}';
    RAISE NOTICE 'replicator already exists — password updated';
END
\$\$;
SQL
echo "==> replicator user ready"

# ----- STEP 3: Create the rewind_user -----
# pg_rewind is a tool that allows a former leader to re-join as a replica
# after a failover. It needs a special user with read access to a few
# system catalog functions (NOT a superuser — minimum privileges only).
psql "$CONN" <<SQL
DO \$\$
BEGIN
    CREATE USER rewind_user WITH PASSWORD '${POSTGRES_PASSWORD}' LOGIN;
    RAISE NOTICE 'Created rewind_user';
EXCEPTION WHEN duplicate_object THEN
    ALTER USER rewind_user WITH PASSWORD '${POSTGRES_PASSWORD}';
    RAISE NOTICE 'rewind_user already exists — password updated';
END
\$\$;
SQL

# GRANT: give the rewind_user permission to call specific system functions.
# GRANTs are inherently idempotent — granting twice does nothing.
# These functions let pg_rewind read the file system layout and compare
# data between the old leader and the current leader.
psql "$CONN" -c "GRANT EXECUTE ON function pg_catalog.pg_ls_dir(text, boolean, boolean) TO rewind_user;"
psql "$CONN" -c "GRANT EXECUTE ON function pg_catalog.pg_stat_file(text, boolean) TO rewind_user;"
psql "$CONN" -c "GRANT EXECUTE ON function pg_catalog.pg_read_binary_file(text) TO rewind_user;"
psql "$CONN" -c "GRANT EXECUTE ON function pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) TO rewind_user;"
echo "==> rewind_user ready (minimum privileges)"

# ----- STEP 4: Create the project's database -----
# Check if the database already exists before creating it.
# "psql -tAc" runs a query and returns just the value (no headers, no padding).
# If the database exists, this returns "1". If not, it returns empty.
DB_EXISTS=$(psql "$CONN" -tAc "SELECT 1 FROM pg_database WHERE datname = '${POSTGRES_DB}';")
if [ "$DB_EXISTS" = "1" ]; then
    echo "==> Database ${POSTGRES_DB} already exists (skip)"
else
    psql "$CONN" -c "CREATE DATABASE ${POSTGRES_DB};"
    echo "==> Created database: ${POSTGRES_DB}"
fi

# ----- STEP 5: Run init.sql + all migration files -----
# Switch the connection to the project database (not the default "postgres" db).
# "${CONN/dbname=postgres/dbname=${POSTGRES_DB}}" is bash string substitution:
# replace "dbname=postgres" with "dbname=<our database name>" in the connection string.
APP_CONN="${CONN/dbname=postgres/dbname=${POSTGRES_DB}}"

# Run init.sql which creates the schema_migrations tracking table
psql "$APP_CONN" -f /scripts/init.sql
echo "==> schema_migrations table created"

# Apply ALL migration files in order.
# This is the same logic as run-migrations.sh but simpler because we're
# already INSIDE the Patroni container (no need for docker exec or HAProxy).
#
# "find ... -name '*.sql' ! -name '*.down.sql'" = find all .sql files
#   but NOT .down.sql files (those are reverse/undo migrations)
# "| sort" = apply in alphabetical order (001 before 002 before 003)
if [ -d /scripts/migrations ]; then
    for MIGRATION in $(find /scripts/migrations -name '*.sql' ! -name '*.down.sql' -type f | sort); do
        # Get just the filename (not the full path)
        BASENAME=$(basename "$MIGRATION")

        # Check if this migration was already applied
        ALREADY=$(psql "$APP_CONN" -tAc "SELECT 1 FROM schema_migrations WHERE filename = '${BASENAME}';" 2>/dev/null || echo "")
        if [ "$ALREADY" = "1" ]; then
            echo "    ${BASENAME}: already applied (skip)"
            continue  # skip to the next migration file
        fi

        echo "    applying: ${BASENAME}"
        # Run the migration inside a TRANSACTION (BEGIN...COMMIT).
        # If any statement fails, the entire migration rolls back
        # (is undone) and nothing is recorded in schema_migrations.
        #
        # "$(cat "$MIGRATION")" reads the entire file content and
        # inserts it between BEGIN and COMMIT.
        #
        # The INSERT at the end records that this migration was applied,
        # so it won't run again on the next deploy.
        psql "$APP_CONN" -v ON_ERROR_STOP=1 <<SQL
BEGIN;
$(cat "$MIGRATION")
INSERT INTO schema_migrations (filename) VALUES ('${BASENAME}');
COMMIT;
SQL
        echo "    ✓ ${BASENAME}"
    done
fi
echo "==> Bootstrap complete. All migrations applied."
