#!/bin/bash
# Patroni container entrypoint.
# Reads passwords from Docker Swarm secret files (mounted at /run/secrets/*)
# and exports them as Patroni env vars before starting Patroni.
#
# WHY this approach?
# Docker Swarm secrets are mounted as files in /run/secrets/, never visible
# in `docker inspect` or `docker service inspect`. Patroni's native env var
# mechanism (PATRONI_*_PASSWORD) needs the value as an env var, so we read
# from the file and export it inside the container — never crossing the host.

set -e

if [ -f /run/secrets/postgres_password ]; then
    export POSTGRES_PASSWORD=$(cat /run/secrets/postgres_password)
    export PATRONI_SUPERUSER_PASSWORD="$POSTGRES_PASSWORD"
    export PATRONI_REWIND_PASSWORD="$POSTGRES_PASSWORD"
fi

if [ -f /run/secrets/replication_password ]; then
    export REPLICATION_PASSWORD=$(cat /run/secrets/replication_password)
    export PATRONI_REPLICATION_PASSWORD="$REPLICATION_PASSWORD"
fi

# Clean up stale Postgres lock files left behind if the container was
# previously killed (SIGKILL / OOM / host crash). Without this, Postgres
# refuses to start with "lock file .s.PGSQL.5432.lock is empty" and
# Patroni enters a "start failed" loop that can only be fixed by wiping
# the entire volume. We check that no Postgres process is actually running
# before removing the lock — if one IS running, we leave it alone.
PGDATA="${PGDATA:-/data/patroni}"
for lockfile in "${PGDATA}/postmaster.pid" "${PGDATA}/.s.PGSQL.5432.lock"; do
    if [ -f "${lockfile}" ]; then
        # If a postgres process is ACTUALLY running, the lock is legitimate
        PG_PID=$(head -1 "${lockfile}" 2>/dev/null || echo "")
        if [ -n "${PG_PID}" ] && kill -0 "${PG_PID}" 2>/dev/null; then
            echo "entrypoint: ${lockfile} belongs to running PID ${PG_PID} — keeping"
        else
            echo "entrypoint: removing stale ${lockfile} (no running postgres)"
            rm -f "${lockfile}"
        fi
    fi
done

# Hand off to the actual Patroni command (CMD from Dockerfile)
exec "$@"
