# ---------------------------------------------------------------------------
# patroni/Dockerfile — builds the Patroni + PostgreSQL 16 Docker image.
#
# WHAT IS PATRONI?
# Patroni is a HIGH AVAILABILITY (HA) manager for PostgreSQL. It runs
# alongside PostgreSQL on each server and handles:
#   - Leader election (which server is the primary/writable database)
#   - Automatic failover (if the leader crashes, promote a replica)
#   - Streaming replication setup (keeping replicas in sync with the leader)
#
# WHY A CUSTOM IMAGE?
# There's no official Docker image that combines PostgreSQL + Patroni.
# We build our own by:
#   1. Starting from Ubuntu 22.04
#   2. Installing PostgreSQL 16 (the database itself)
#   3. Installing Patroni (the HA manager) via pip
#   4. Copying our config files and migration scripts
#
# THIS IMAGE RUNS ON ALL 3 SERVERS (rishi-1, rishi-2, rishi-3)
# Each server gets one Patroni container. One becomes the leader (accepts
# writes), the other two become replicas (read-only copies).
# ---------------------------------------------------------------------------

# Start from Ubuntu 22.04 (a stable, well-supported Linux distribution)
FROM ubuntu:24.04

# Image labels for provenance tracking
LABEL org.opencontainers.image.source="https://github.com/dolr-ai/yral-rishi-hetzner-infra-template"
LABEL org.opencontainers.image.description="dolr-ai Patroni + PostgreSQL 16 HA image"

# Tell apt-get (Ubuntu's package manager) to not ask interactive questions
# during installation (there's no human to answer them in a Docker build)
ENV DEBIAN_FRONTEND=noninteractive

# Add PostgreSQL 16's binary directory to the PATH.
# PATH is the list of directories the system searches when you type a command.
# Patroni needs to find PostgreSQL's tools (initdb, pg_ctl, etc.) here.
ENV PATH="/usr/lib/postgresql/16/bin:${PATH}"

# INSTALL EVERYTHING WE NEED:
# This is one big RUN command (joined with &&) to create a single Docker layer.
#
# Step 1: Update the package list + install basic tools
#   python3, python3-pip: Python (needed to run Patroni, which is written in Python)
#   curl: download files from the internet
#   gnupg2: cryptographic tool for verifying package signatures
#   lsb-release: tells us which Ubuntu version we're running (for the PostgreSQL repo)
#
# Step 2: Add PostgreSQL's official package repository (PGDG)
#   We add their signing key (ACCC4CF8.asc) so apt trusts their packages
#
# Step 3: Install PostgreSQL 16 (the database server + client tools)
#
# Step 4: Install Patroni via pip (Python's package manager)
#   "patroni[etcd3]" = Patroni with the etcd3 client extension
#   "psycopg2-binary" = PostgreSQL adapter for Python (Patroni needs it)
#
# Step 5: Clean up apt cache (saves ~100MB in the final image)
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

# Create the data directory where PostgreSQL stores its files.
# /data/patroni is where the actual database files live (tables, indexes, WAL).
# This directory is mounted as a Docker volume so data survives container restarts.
#
# PERMISSIONS:
# - "chown postgres:postgres" = make the postgres user the owner
# - "chmod 0700" = ONLY the owner can read/write/enter this directory
#   PostgreSQL REFUSES to start if the data directory has looser permissions
#   (this is a security feature to prevent other users from reading DB files)
RUN mkdir -p /data/patroni /scripts && \
    chown -R postgres:postgres /data /data/patroni /scripts && \
    chmod 0700 /data/patroni

# COPY our configuration and scripts into the image.
#
# NOTE: this Dockerfile is built with context=. (the repo root), not
# context=./patroni. This is why paths start with "patroni/" — they're
# relative to the repo root, not to the patroni/ directory.
#
# patroni.yml: Patroni's main configuration file (etcd connection, PostgreSQL settings)
COPY patroni/patroni.yml /etc/patroni.yml
# init.sql: creates the schema_migrations tracking table (run once at bootstrap)
COPY patroni/init.sql /scripts/init.sql
# post_init.sh: creates users, database, and runs all migrations (run once at bootstrap)
COPY patroni/post_init.sh /scripts/post_init.sh
# entrypoint.sh: reads Swarm secrets, cleans up lock files, starts Patroni
COPY patroni/entrypoint.sh /entrypoint.sh
# migrations/: SQL migration files so a fresh cluster bootstraps to the latest schema
COPY migrations/ /scripts/migrations/
# Make the scripts executable (chmod +x = allow execution)
RUN chmod +x /scripts/post_init.sh /entrypoint.sh

# Switch to the "postgres" user for all runtime operations.
# PostgreSQL requires running as a non-root user (it refuses to start as root).
USER postgres

# ENTRYPOINT: the first thing that runs when the container starts.
# Our entrypoint.sh reads Swarm secrets and exports them as env vars,
# cleans up stale lock files, then starts Patroni via "exec $@".
ENTRYPOINT ["/entrypoint.sh"]

# CMD: the default command passed to the entrypoint.
# "patroni /etc/patroni.yml" starts Patroni with our configuration file.
CMD ["patroni", "/etc/patroni.yml"]
