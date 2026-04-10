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
mv backup/stack.yml ./backup-stack.yml 2>/dev/null || true

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
    -c etcd-stack.yml \
    -c patroni-stack.yml \
    -c haproxy-stack.yml \
    "${SWARM_STACK}"

echo ""
echo "Stack deployed. Service status:"
docker stack services "${SWARM_STACK}"

# ---- Set up daily backup cron job (runs on rishi-1 only, which is where
#      this script executes). The backup container runs as a one-off
#      `docker run` on the per-project overlay network so it can reach
#      HAProxy by service name. Swarm stack deployment can't be used for
#      the backup because adding a 4th compose file with an overlay
#      reference causes a Docker naming conflict for long stack names.
if [ -n "${BACKUP_S3_ACCESS_KEY:-}" ] && [ -n "${BACKUP_S3_SECRET_KEY:-}" ]; then
    BACKUP_IMAGE="${IMAGE_REPO}-backup:${IMAGE_TAG}"
    PG_PASS=$(cat /run/secrets/${SWARM_STACK}_postgres_password 2>/dev/null || \
              docker secret inspect ${SWARM_STACK}_postgres_password --format '{{.Spec.Data}}' 2>/dev/null | base64 -d || \
              echo "${POSTGRES_PASSWORD}")

    # Build the docker run command for the cron entry
    BACKUP_CMD="docker run --rm --network ${OVERLAY_NETWORK}"
    BACKUP_CMD="${BACKUP_CMD} -e PGHOST=haproxy-rishi-1 -e PGPORT=5432 -e PGUSER=postgres"
    BACKUP_CMD="${BACKUP_CMD} -e PGPASSWORD='${PG_PASS}'"
    BACKUP_CMD="${BACKUP_CMD} -e POSTGRES_DB=${POSTGRES_DB}"
    BACKUP_CMD="${BACKUP_CMD} -e PROJECT_REPO=${PROJECT_REPO}"
    BACKUP_CMD="${BACKUP_CMD} -e BACKUP_S3_ENDPOINT=${BACKUP_S3_ENDPOINT}"
    BACKUP_CMD="${BACKUP_CMD} -e BACKUP_S3_BUCKET=${BACKUP_S3_BUCKET}"
    BACKUP_CMD="${BACKUP_CMD} -e BACKUP_RETENTION_DAILY=${BACKUP_RETENTION_DAILY:-7}"
    BACKUP_CMD="${BACKUP_CMD} -e BACKUP_RETENTION_WEEKLY=${BACKUP_RETENTION_WEEKLY:-4}"
    BACKUP_CMD="${BACKUP_CMD} -e AWS_ACCESS_KEY_ID='${BACKUP_S3_ACCESS_KEY}'"
    BACKUP_CMD="${BACKUP_CMD} -e AWS_SECRET_ACCESS_KEY='${BACKUP_S3_SECRET_KEY}'"
    BACKUP_CMD="${BACKUP_CMD} ${BACKUP_IMAGE}"

    # Idempotent cron entry: remove any existing entry for this project, add new one.
    # Runs daily at 3:00 AM UTC. Logs go to Docker's logging driver (captured by
    # `docker logs` on the container if it's still running, or lost after --rm).
    CRON_TAG="# ${PROJECT_REPO}_daily_backup"
    (crontab -l 2>/dev/null | grep -v "${CRON_TAG}"; \
     echo "0 3 * * * ${BACKUP_CMD} ${CRON_TAG}") | crontab -
    echo "==> Daily backup cron installed (3:00 AM UTC via docker run on ${OVERLAY_NETWORK})"
else
    echo "==> Backup S3 credentials not set — skipping backup cron setup"
fi
