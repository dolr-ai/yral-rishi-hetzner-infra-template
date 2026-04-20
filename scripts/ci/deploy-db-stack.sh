#!/bin/bash
# ---------------------------------------------------------------------------
# deploy-db-stack.sh — deploys the database tier to Docker Swarm.
#
# WHERE DOES THIS RUN?
# On rishi-1 (the Swarm manager) via SSH from GitHub Actions CI.
# It's called by the "Deploy etcd + Patroni + HAProxy" job in deploy.yml.
#
# WHAT DOES IT DO?
# 1. Loads project.config (to get stack name, network name, etc.)
# 2. Moves stack YAML files to flat names (docker stack deploy needs them)
# 3. Logs into GHCR (so Swarm workers can pull private images)
# 4. Creates Docker Swarm secrets (postgres_password, replication_password)
# 5. Runs "docker stack deploy" with 3 compose files (etcd + patroni + haproxy)
#
# WHAT IS "docker stack deploy"?
# It reads one or more compose YAML files and creates/updates Swarm services
# across all servers in the cluster. It's the Swarm equivalent of
# "docker compose up" but works across MULTIPLE servers.
#
# REQUIRED ENVIRONMENT VARIABLES (passed by CI):
#   IMAGE_TAG            — the git commit SHA (used as the Docker image tag)
#   POSTGRES_PASSWORD    — the PostgreSQL superuser password
#   REPLICATION_PASSWORD — the password for streaming replication
#   GITHUB_TOKEN         — for authenticating with GHCR (to pull private images)
#   GITHUB_ACTOR         — the GitHub username (for GHCR login)
#   STACK_DIR            — path on the server where CI uploaded the stack files
# ---------------------------------------------------------------------------

# Stop on any error
set -e

# Change to the directory where CI uploaded the stack files
# (e.g., /home/deploy/rishi-hetzner-infra-template-db-stack/)
cd "${STACK_DIR}"

# Load ALL variables from project.config into the shell environment.
# "set -a" = auto-export every variable (so child processes see them too)
# "source" = read the file and execute each line (KEY=value becomes a variable)
# "set +a" = stop auto-exporting
# After this, all ${VAR} references in the stack YAML files will be substituted.
set -a
source ./project.config
set +a

# Print the loaded config for debugging in CI logs
echo "==> Project config loaded:"
echo "    PROJECT_NAME=${PROJECT_NAME}"
echo "    SWARM_STACK=${SWARM_STACK}"
echo "    OVERLAY_NETWORK=${OVERLAY_NETWORK}"
echo "    PATRONI_SCOPE=${PATRONI_SCOPE}"
echo "    POSTGRES_DB=${POSTGRES_DB}"

# CI uploads files with their directory structure (etcd/stack.yml, patroni/stack.yml).
# "docker stack deploy" expects files in the CURRENT directory, so we flatten them.
# "2>/dev/null || true" = ignore errors if the file doesn't exist (idempotent)
mv etcd/stack.yml ./etcd-stack.yml 2>/dev/null || true
mv patroni/stack.yml ./patroni-stack.yml 2>/dev/null || true
mv haproxy/stack.yml ./haproxy-stack.yml 2>/dev/null || true
mv haproxy/haproxy.cfg ./haproxy.cfg 2>/dev/null || true
mv backup/stack.yml ./backup-stack.yml 2>/dev/null || true

# Log into GHCR (GitHub Container Registry) so Swarm workers can pull
# private Docker images. "--with-registry-auth" in the stack deploy command
# passes the login credentials to all Swarm nodes.
echo "${GITHUB_TOKEN}" | docker login ghcr.io -u "${GITHUB_ACTOR}" --password-stdin

# ----- CREATE DOCKER SWARM SECRETS -----
# Swarm secrets are encrypted key-value pairs stored by the Swarm manager.
# Containers access them as files at /run/secrets/<name> (RAM-only, never on disk).
#
# WHY NAMESPACED NAMES (e.g., "my-service-db_postgres_password")?
# Swarm secrets are CLUSTER-WIDE — there's only one "postgres_password" per cluster.
# If two services both tried to create "postgres_password", they'd conflict.
# By prefixing with the stack name, each service has its own isolated secrets.
#
# WHY CREATE-IF-MISSING (not update)?
# Swarm secrets are IMMUTABLE — once created, you can't change the value.
# To rotate a password: delete the old secret, create a new one, redeploy.
PG_SECRET_NAME="${SWARM_STACK}_postgres_password"
REP_SECRET_NAME="${SWARM_STACK}_replication_password"

# Check if the postgres password secret already exists
# "docker secret ls" lists all secrets; "grep -q" searches silently
if ! docker secret ls --format '{{.Name}}' | grep -q "^${PG_SECRET_NAME}$"; then
    # Create the secret: pipe the password into "docker secret create"
    # The "-" at the end means "read the value from stdin (the pipe)"
    echo "${POSTGRES_PASSWORD}" | docker secret create "${PG_SECRET_NAME}" -
    echo "  Created ${PG_SECRET_NAME}"
else
    echo "  ${PG_SECRET_NAME} already exists (skipping)"
fi

# Same for the replication password
if ! docker secret ls --format '{{.Name}}' | grep -q "^${REP_SECRET_NAME}$"; then
    echo "${REPLICATION_PASSWORD}" | docker secret create "${REP_SECRET_NAME}" -
    echo "  Created ${REP_SECRET_NAME}"
else
    echo "  ${REP_SECRET_NAME} already exists (skipping)"
fi

# Make IMAGE_TAG available as an env var for the stack files
export IMAGE_TAG="${IMAGE_TAG}"

# ----- Compute content sha for haproxy.cfg (unblocks CI after content drift) -----
# Docker Swarm configs are IMMUTABLE; only labels can be updated. If the
# haproxy.cfg file changes content, the next `docker stack deploy` fails with:
#   "failed to update config <stack>_haproxy_cfg:
#    rpc error: InvalidArgument: only updates to Labels are allowed"
# This exact error broke template deploys from 2026-04-12 through 2026-04-20.
#
# Fix: version the Swarm config name by a content sha so every content change
# creates a NEW config. haproxy/stack.yml references `${HAPROXY_CFG_SHA}`;
# the old config is orphaned (no one references it) and we prune it below.
#
# Truncating to 8 chars keeps the combined config name within Swarm's 63-char
# limit even at the template's maximum PROJECT_NAME of 39 chars:
#   <SWARM_STACK>_haproxy_cfg_<sha8>
#   = (PROJECT_NAME + "-db") + "_" + "haproxy_cfg" + "_" + 8
#   = 42 + 1 + 11 + 1 + 8 = 63 ✓
# 8 hex chars = 2^32 name space; collision risk across realistic revisions is
# negligible and Swarm `docker config rm` refuses if in use anyway.
export HAPROXY_CFG_SHA=$(sha256sum ./haproxy.cfg | head -c 8)
echo "==> haproxy.cfg sha (for versioned Swarm config name): ${HAPROXY_CFG_SHA}"

# ----- PRE-FLIGHT: Check cluster health before deploying -----
# The rolling update strategy (stop-first, 1 at a time) temporarily takes a
# node offline. If the cluster is already degraded (e.g., replicas in "start
# failed"), stopping the leader for an update could cause a total outage.
# We warn about this so CI logs make the risk visible.
echo ""
echo "==> Pre-flight: checking Patroni cluster health..."
PRE_C=$(docker ps -qf "name=${SWARM_STACK}_patroni-rishi" | head -1)
if [ -n "${PRE_C}" ]; then
    PRE_LIST=$(docker exec "${PRE_C}" patronictl -c /etc/patroni.yml list 2>/dev/null || echo "")
    if [ -n "${PRE_LIST}" ]; then
        echo "${PRE_LIST}"
        PRE_STREAMING=$(echo "${PRE_LIST}" | grep -c "streaming" || true)
        PRE_FAILED=$(echo "${PRE_LIST}" | grep -c "start failed" || true)
        PRE_LEADER=$(echo "${PRE_LIST}" | grep -c "Leader" || true)
        echo ""
        if [ "${PRE_FAILED}" -gt 0 ]; then
            echo "⚠ WARNING: ${PRE_FAILED} Patroni node(s) in 'start failed' state"
            echo "  Consider running: bash scripts/fix-failed-replicas.sh"
        fi
        if [ "${PRE_LEADER}" -ge 1 ] && [ "${PRE_STREAMING}" -lt 2 ]; then
            echo "⚠ WARNING: cluster is DEGRADED (${PRE_STREAMING}/2 replicas streaming)"
            echo "  Rolling update may cause brief downtime if the leader is restarted"
        fi
        if [ "${PRE_LEADER}" -ge 1 ] && [ "${PRE_STREAMING}" -ge 2 ] && [ "${PRE_FAILED}" -eq 0 ]; then
            echo "✓ Cluster healthy: ${PRE_LEADER} leader, ${PRE_STREAMING} streaming"
        fi
    fi
else
    echo "  No existing Patroni containers found (first deploy?)"
fi
echo ""

# ----- DEPLOY THE STACK -----
# "docker stack deploy" creates or updates all services defined in the
# compose files. It merges multiple files with "-c" (combine).
#
# --with-registry-auth: pass GHCR login credentials to worker nodes
#   so they can pull private images (otherwise they'd get "unauthorized")
#
# -c etcd-stack.yml: 3 etcd containers (leader election coordination)
# -c patroni-stack.yml: 3 Patroni+PostgreSQL containers (database HA)
# -c haproxy-stack.yml: 2 HAProxy containers (DB connection routing)
#
# "${SWARM_STACK}" is the stack name (e.g., "rishi-hetzner-infra-template-db")
docker stack deploy \
    --with-registry-auth \
    -c etcd-stack.yml \
    -c patroni-stack.yml \
    -c haproxy-stack.yml \
    "${SWARM_STACK}"

echo ""
echo "Stack deployed. Service status:"
# Show all services in the stack with their replica counts
docker stack services "${SWARM_STACK}"

# ----- Prune old versioned haproxy_cfg configs -----
# After the service rollout completes, the previous-version config is
# orphaned (no service references it). Remove any ${SWARM_STACK}_haproxy_cfg*
# whose name isn't the current sha.
#
# Also catches the LEGACY unversioned `${SWARM_STACK}_haproxy_cfg` name
# (from before this fix) — that config is now orphaned and safe to prune.
#
# `docker config rm` refuses to remove a config still in use by any service,
# so this is safe: we can't accidentally break a running service.
echo ""
echo "==> Pruning orphaned haproxy_cfg configs (keeping ${HAPROXY_CFG_SHA})..."
docker config ls --format '{{.Name}}' \
    | grep -E "^${SWARM_STACK}_haproxy_cfg(_|$)" \
    | grep -v "^${SWARM_STACK}_haproxy_cfg_${HAPROXY_CFG_SHA}$" \
    | while read -r OLD_CFG; do
        if docker config rm "${OLD_CFG}" >/dev/null 2>&1; then
            echo "  removed ${OLD_CFG}"
        else
            echo "  skipped ${OLD_CFG} (still referenced by a service — will prune on next deploy)"
        fi
    done

echo ""
echo "==> Daily backups are handled by .github/workflows/backup.yml (3:00 AM UTC)."
echo "    To trigger manually: gh workflow run backup.yml"
