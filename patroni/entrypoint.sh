#!/bin/bash
# ---------------------------------------------------------------------------
# entrypoint.sh — the FIRST script that runs inside the Patroni container.
#
# WHAT IS AN ENTRYPOINT?
# In Docker, the "entrypoint" is the first program that runs when a
# container starts. It runs BEFORE the main application (Patroni in our
# case). Think of it as a "setup step" before the real work begins.
#
# WHAT DOES THIS SCRIPT DO?
# 1. Reads database passwords from Docker Swarm secret FILES
# 2. Exports them as ENVIRONMENT VARIABLES (so Patroni can read them)
# 3. Cleans up stale lock files from previous crashes
# 4. Starts Patroni (the actual database manager)
#
# WHY READ FROM FILES, NOT ENV VARS?
# Docker Swarm secrets are mounted as files at /run/secrets/ — they're
# stored in RAM (tmpfs), never written to disk, and invisible to
# `docker inspect`. This is more secure than environment variables,
# which ARE visible in `docker inspect` to anyone in the docker group.
#
# Patroni needs the passwords as environment variables (PATRONI_*_PASSWORD),
# so we READ from the file and EXPORT as env vars — all inside the
# container, never crossing the host boundary.
# ---------------------------------------------------------------------------

# "set -e" means "if ANY command fails, stop the script immediately."
# Without this, the script would continue after an error, potentially
# starting Patroni with missing passwords.
set -e

# ----- STEP 1: Read the PostgreSQL superuser password -----
# Check if the secret file exists (it should — Docker Swarm mounts it)
if [ -f /run/secrets/postgres_password ]; then
    # "cat" reads the file contents. "$(...)" captures the output.
    # "export" makes the variable available to child processes (Patroni).
    export POSTGRES_PASSWORD=$(cat /run/secrets/postgres_password)

    # Patroni uses specific env var names for passwords:
    # PATRONI_SUPERUSER_PASSWORD = the main postgres user's password
    # PATRONI_REWIND_PASSWORD = password for the pg_rewind user
    #   (pg_rewind is used when a former leader re-joins as a replica)
    export PATRONI_SUPERUSER_PASSWORD="$POSTGRES_PASSWORD"
    export PATRONI_REWIND_PASSWORD="$POSTGRES_PASSWORD"
fi

# ----- STEP 2: Read the replication password -----
# This password is used by replicas to connect to the leader for
# streaming replication (keeping their data in sync).
if [ -f /run/secrets/replication_password ]; then
    export REPLICATION_PASSWORD=$(cat /run/secrets/replication_password)
    export PATRONI_REPLICATION_PASSWORD="$REPLICATION_PASSWORD"
fi

# ----- STEP 3: Clean up stale lock files -----
# WHAT ARE LOCK FILES?
# When PostgreSQL starts, it creates lock files (postmaster.pid and
# .s.PGSQL.5432.lock) to prevent two PostgreSQL instances from
# running on the same data directory simultaneously.
#
# THE PROBLEM:
# If the container is killed (SIGKILL, OOM killer, host crash),
# PostgreSQL doesn't get a chance to clean up these files. On the
# next start, PostgreSQL sees the lock files and thinks another
# instance is still running → refuses to start → Patroni reports
# "start failed" → the container enters a crash loop.
#
# THE FIX:
# Check if the process ID in the lock file is actually running.
# If not → the lock is stale → remove it safely.

# PGDATA is where PostgreSQL stores its data files.
# "${PGDATA:-/data/patroni}" means "use PGDATA if set, otherwise /data/patroni"
PGDATA="${PGDATA:-/data/patroni}"

# Loop through both lock files
for lockfile in "${PGDATA}/postmaster.pid" "${PGDATA}/.s.PGSQL.5432.lock"; do
    # Check if the lock file exists
    if [ -f "${lockfile}" ]; then
        # Read the first line of the file — it contains the process ID (PID)
        # of the PostgreSQL instance that created the lock.
        PG_PID=$(head -1 "${lockfile}" 2>/dev/null || echo "")

        # "kill -0 PID" checks if a process with that PID is running.
        # It doesn't actually kill anything — 0 is a "check only" signal.
        if [ -n "${PG_PID}" ] && kill -0 "${PG_PID}" 2>/dev/null; then
            # Process IS running → lock is legitimate → don't touch it
            echo "entrypoint: ${lockfile} belongs to running PID ${PG_PID} — keeping"
        else
            # Process is NOT running → lock is stale → safe to remove
            echo "entrypoint: removing stale ${lockfile} (no running postgres)"
            rm -f "${lockfile}"
        fi
    fi
done

# ----- STEP 4: Start Patroni -----
# "exec" replaces the current process (this script) with the command
# that follows. "$@" means "all arguments passed to this script."
#
# Docker passes the CMD from the Dockerfile as arguments:
#   CMD ["patroni", "/etc/patroni.yml"]
# So "$@" becomes: patroni /etc/patroni.yml
#
# WHY "exec" instead of just running the command?
# Without exec, Patroni would run as a CHILD process of this script.
# Docker sends signals (like SIGTERM for graceful shutdown) to PID 1.
# With exec, Patroni BECOMES PID 1 and receives signals directly.
# Without exec, signals would go to the bash script (which ignores them)
# and Patroni would never shut down gracefully.
exec "$@"
