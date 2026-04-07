#!/bin/bash
# Runs ON the Swarm manager (rishi-1) over SSH from CI.
# Deploys the project's Swarm stack (etcd + Patroni + HAProxy).
#
# Required env vars (passed by CI from GitHub Actions):
#   IMAGE_TAG               — git SHA for immutable image versioning
#   POSTGRES_PASSWORD       — superuser password for PostgreSQL
#   REPLICATION_PASSWORD    — replication user password
#   GITHUB_TOKEN            — for GHCR docker login
#   GITHUB_ACTOR            — GHCR username
#   STACK_DIR               — path to the dir on the server where stack files + project.config live
#
# Plus: every variable defined in project.config (sourced below) is exported
# into the shell so `docker stack deploy` can interpolate ${PROJECT_NAME},
# ${SWARM_STACK}, ${OVERLAY_NETWORK}, ${ETCD_TOKEN}, etc. in the stack files.

set -e

cd "${STACK_DIR}"

# Auto-export every line in project.config (`set -a`) so docker stack deploy
# sees them as shell env vars and interpolates ${VAR} in the stack files.
set -a
source ./project.config
set +a

echo "==> Project config loaded:"
echo "    PROJECT_NAME=${PROJECT_NAME}"
echo "    SWARM_STACK=${SWARM_STACK}"
echo "    OVERLAY_NETWORK=${OVERLAY_NETWORK}"
echo "    PATRONI_SCOPE=${PATRONI_SCOPE}"
echo "    POSTGRES_DB=${POSTGRES_DB}"

# SCP preserves directory structure; flatten so stack deploy finds files locally
mv etcd/stack.yml ./etcd-stack.yml 2>/dev/null || true
mv patroni/stack.yml ./patroni-stack.yml 2>/dev/null || true
mv haproxy/stack.yml ./haproxy-stack.yml 2>/dev/null || true
mv haproxy/haproxy.cfg ./haproxy.cfg 2>/dev/null || true

# Login to GHCR so workers can pull images via --with-registry-auth
echo "${GITHUB_TOKEN}" | docker login ghcr.io -u "${GITHUB_ACTOR}" --password-stdin

# Create Docker Swarm secrets — namespaced with the stack name from project.config.
# WHY namespaced names?
# Swarm secrets are CLUSTER-WIDE, not per-stack. Two services in the same
# Swarm would conflict on a generic name like `postgres_password`. The
# stack name prefix isolates each project's secrets from each other.
#
# WHY only create-if-missing?
# Swarm secrets are immutable — you can't update a secret in place. To
# rotate a password, manually `docker secret rm` first, then redeploy.
PG_SECRET_NAME="${SWARM_STACK}_postgres_password"
REP_SECRET_NAME="${SWARM_STACK}_replication_password"

if ! docker secret ls --format '{{.Name}}' | grep -q "^${PG_SECRET_NAME}$"; then
    echo "${POSTGRES_PASSWORD}" | docker secret create "${PG_SECRET_NAME}" -
    echo "  Created ${PG_SECRET_NAME}"
else
    echo "  ${PG_SECRET_NAME} already exists (skipping)"
fi
if ! docker secret ls --format '{{.Name}}' | grep -q "^${REP_SECRET_NAME}$"; then
    echo "${REPLICATION_PASSWORD}" | docker secret create "${REP_SECRET_NAME}" -
    echo "  Created ${REP_SECRET_NAME}"
else
    echo "  ${REP_SECRET_NAME} already exists (skipping)"
fi

# IMAGE_TAG was already exported by the CI workflow, but be explicit for clarity
export IMAGE_TAG="${IMAGE_TAG}"

# Deploy (or update) the stack. Idempotent.
docker stack deploy \
    --with-registry-auth \
    --compose-file etcd-stack.yml \
    --compose-file patroni-stack.yml \
    --compose-file haproxy-stack.yml \
    "${SWARM_STACK}"

echo ""
echo "Stack deployed. Service status:"
docker stack services "${SWARM_STACK}"
