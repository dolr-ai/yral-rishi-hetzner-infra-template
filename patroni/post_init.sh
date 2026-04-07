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

set -e

CONN="$1"

# Read passwords from Docker Swarm secrets (preferred) or env vars (fallback).
# The entrypoint already exported these when called by Patroni, but post_init.sh
# may run in a fresh subshell so we re-read them here to be safe.
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

# POSTGRES_DB is the database name to create. Comes from project.config via
# patroni/stack.yml's environment block.
if [ -z "$POSTGRES_DB" ]; then
    echo "FATAL: POSTGRES_DB env var not set (should come from project.config via stack.yml)"
    exit 1
fi

echo "==> Running post-bootstrap initialization..."

# Set the postgres superuser password for remote (md5) connections.
# Local connections use trust auth, so this isn't needed for psql here,
# but the counter app connects via the overlay network and needs md5.
psql "$CONN" -c "ALTER USER postgres WITH PASSWORD '${POSTGRES_PASSWORD}';"
echo "==> Set postgres password for remote auth"

# Create the replicator user for streaming replication
psql "$CONN" -c "CREATE USER replicator WITH REPLICATION PASSWORD '${REPLICATION_PASSWORD}';"
echo "==> Created replicator user"

# Create the rewind user with MINIMUM privileges needed for pg_rewind.
# Per Patroni docs: https://patroni.readthedocs.io/en/latest/security.html
# Just LOGIN + execute on a few catalog functions. NOT a superuser.
psql "$CONN" -c "CREATE USER rewind_user WITH PASSWORD '${POSTGRES_PASSWORD}' LOGIN;"
psql "$CONN" -c "GRANT EXECUTE ON function pg_catalog.pg_ls_dir(text, boolean, boolean) TO rewind_user;"
psql "$CONN" -c "GRANT EXECUTE ON function pg_catalog.pg_stat_file(text, boolean) TO rewind_user;"
psql "$CONN" -c "GRANT EXECUTE ON function pg_catalog.pg_read_binary_file(text) TO rewind_user;"
psql "$CONN" -c "GRANT EXECUTE ON function pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) TO rewind_user;"
echo "==> Created rewind_user (minimum privileges, NOT superuser)"

# Create the project database (name from POSTGRES_DB env var)
psql "$CONN" -c "CREATE DATABASE ${POSTGRES_DB};"
echo "==> Created database: ${POSTGRES_DB}"

# Connect to the new database and run init.sql to create the business-logic schema
APP_CONN="${CONN/dbname=postgres/dbname=${POSTGRES_DB}}"
psql "$APP_CONN" -f /scripts/init.sql
echo "==> init.sql applied. Bootstrap complete."
