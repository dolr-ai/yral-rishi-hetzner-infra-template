# WHY build a custom image?
# Patroni is not a standalone application — it needs to be installed ON TOP of PostgreSQL.
# No official public Docker image combines both. We build our own simple image.
#
# This image contains:
# - Ubuntu 22.04 base
# - PostgreSQL 16 (the database itself)
# - Patroni + etcd3 client (the HA manager)

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
# PostgreSQL 16 bins (initdb, pg_ctl, etc.) are here — Patroni needs them in PATH
ENV PATH="/usr/lib/postgresql/16/bin:${PATH}"

# Install PostgreSQL 16 from the official PGDG repository
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 python3-pip curl gnupg2 lsb-release && \
    echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list && \
    curl -sSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        | gpg --dearmor > /etc/apt/trusted.gpg.d/postgresql.gpg && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        postgresql-16 postgresql-client-16 && \
    pip3 install --no-cache-dir "patroni[etcd3]" psycopg2-binary && \
    rm -rf /var/lib/apt/lists/*

# Create data directory and set postgres user as owner.
# /data must also be writable by postgres because Patroni renames /data/patroni
# to /data/patroni.failed if bootstrap fails — that requires write on /data parent.
# /data/patroni MUST be 0700 — PostgreSQL refuses to start with looser perms.
RUN mkdir -p /data/patroni /scripts && \
    chown -R postgres:postgres /data /data/patroni /scripts && \
    chmod 0700 /data/patroni

# Copy config and scripts
# NOTE: this Dockerfile is built with context=. (repo root), not context=./patroni.
# This lets us COPY both patroni/* files and the migrations/ directory.
COPY patroni/patroni.yml /etc/patroni.yml
COPY patroni/init.sql /scripts/init.sql
COPY patroni/post_init.sh /scripts/post_init.sh
COPY patroni/entrypoint.sh /entrypoint.sh
# Migration files so post_init.sh can bootstrap a fresh cluster to the latest schema
COPY migrations/ /scripts/migrations/
RUN chmod +x /scripts/post_init.sh /entrypoint.sh

# Run as postgres user (never as root)
USER postgres

# Entrypoint reads Docker Swarm secrets and exports them as env vars,
# then execs the CMD. This is how Patroni gets passwords without them
# being visible in `docker inspect`.
ENTRYPOINT ["/entrypoint.sh"]
CMD ["patroni", "/etc/patroni.yml"]
