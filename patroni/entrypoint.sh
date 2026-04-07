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

# Hand off to the actual Patroni command (CMD from Dockerfile)
exec "$@"
