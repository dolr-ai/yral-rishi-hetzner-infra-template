#!/bin/bash
# Runs ONCE after the PostgreSQL cluster is first initialized.
# Patroni passes a connection string as $1, e.g.:
#   "host=/tmp port=5432 user=postgres dbname=postgres"
#
# WHY this script exists:
# Patroni's initdb creates a bare cluster. We need to:
#   1. Set the postgres user's password (initdb leaves it unset)
#   2. Create replicator and rewind_user roles
#   3. Create the project's database (name from POSTGRES_DB env var)
#   4. Run patroni/init.sql to create the business-logic schema
#
# IDEMPOTENCY:
# Every statement uses IF NOT EXISTS, DO...EXCEPTION, or ON CONFLICT so
# that re-running this script (e.g., after a Patroni re-bootstrap that
# finds existing data) is harmless. This was the #1 cause of "database
# corruption" in earlier versions — a re-bootstrap tried to re-create
# users/databases, crashed on "already exists", and left the cluster in
# an unrecoverable state.

set -e

CONN="$1"

# Read passwords from Docker Swarm secrets (preferred) or env vars (fallback).
if [ -f /run/secrets/postgres_password ]; then
    POSTGRES_PASSWORD=$(cat /run/secrets/postgres_password)
fi
if [ -f /run/secrets/replication_password ]; then
    REPLICATION_PASSWORD=$(cat /run/secrets/replication_password)
fi

if [ -z "$POSTGRES_PASSWORD" ] || [ -z "$REPLICATION_PASSWORD" ]; then
    echo "FATAL: POSTGRES_PASSWORD or REPLICATION_PASSWORD not set"
    exit 1
fi

if [ -z "$POSTGRES_DB" ]; then
    echo "FATAL: POSTGRES_DB env var not set (should come from project.config via stack.yml)"
    exit 1
fi

echo "==> Running post-bootstrap initialization (idempotent)..."

# 1. Set the postgres superuser password (ALTER is always safe to re-run)
psql "$CONN" -c "ALTER USER postgres WITH PASSWORD '${POSTGRES_PASSWORD}';"
echo "==> Set postgres password"

# 2. Create the replicator user (idempotent via DO...EXCEPTION)
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

# 3. Create the rewind_user (idempotent via DO...EXCEPTION)
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
# GRANTs are idempotent by nature (granting twice is a no-op)
psql "$CONN" -c "GRANT EXECUTE ON function pg_catalog.pg_ls_dir(text, boolean, boolean) TO rewind_user;"
psql "$CONN" -c "GRANT EXECUTE ON function pg_catalog.pg_stat_file(text, boolean) TO rewind_user;"
psql "$CONN" -c "GRANT EXECUTE ON function pg_catalog.pg_read_binary_file(text) TO rewind_user;"
psql "$CONN" -c "GRANT EXECUTE ON function pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) TO rewind_user;"
echo "==> rewind_user ready (minimum privileges)"

# 4. Create the project database (idempotent — check pg_database first)
DB_EXISTS=$(psql "$CONN" -tAc "SELECT 1 FROM pg_database WHERE datname = '${POSTGRES_DB}';")
if [ "$DB_EXISTS" = "1" ]; then
    echo "==> Database ${POSTGRES_DB} already exists (skip)"
else
    psql "$CONN" -c "CREATE DATABASE ${POSTGRES_DB};"
    echo "==> Created database: ${POSTGRES_DB}"
fi

# 5. Run init.sql in the project database (init.sql itself uses IF NOT EXISTS
#    and ON CONFLICT DO NOTHING, so it's also idempotent)
APP_CONN="${CONN/dbname=postgres/dbname=${POSTGRES_DB}}"
psql "$APP_CONN" -f /scripts/init.sql
echo "==> init.sql applied. Bootstrap complete."
