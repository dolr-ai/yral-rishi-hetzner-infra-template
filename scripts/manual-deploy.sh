#!/bin/bash
# =============================================================================
# manual-deploy.sh — emergency deploy that bypasses GitHub Actions.
#
# USE THIS ONLY WHEN GitHub Actions is down and you need to push a fix.
# Normal deploys should always go through CI (push to main).
#
# What it does (same steps as CI, run from your Mac):
#   1. Builds the app image locally
#   2. Pushes to GHCR
#   3. SCPs files to each server
#   4. Runs deploy-app.sh on rishi-1 (canary), then rishi-2
#
# Usage:
#   bash scripts/manual-deploy.sh                    # deploy HEAD
#   bash scripts/manual-deploy.sh --tag abc123       # deploy specific tag
#   bash scripts/manual-deploy.sh --server-1-only    # canary only
#
# PREREQUISITES:
#   - Docker running locally
#   - gh auth status → logged in
#   - ~/.ssh/rishi-hetzner-ci-key accessible
#   - GHCR push access (docker login ghcr.io)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

set -a
source "${REPO_ROOT}/project.config"
source "${REPO_ROOT}/servers.config"
set +a

SSH_KEY="${SSH_KEY_PATH/#\~/$HOME}"
IMAGE_TAG=""
SERVER_1_ONLY="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --tag) IMAGE_TAG="$2"; shift 2 ;;
        --server-1-only) SERVER_1_ONLY="true"; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

[ -z "${IMAGE_TAG}" ] && IMAGE_TAG=$(git -C "${REPO_ROOT}" rev-parse HEAD)
echo "==> MANUAL DEPLOY (bypassing CI)"
echo "    project: ${PROJECT_REPO}"
echo "    tag:     ${IMAGE_TAG}"
echo "    servers: ${SERVER_1_IP}$([ "${SERVER_1_ONLY}" = "false" ] && echo " + ${SERVER_2_IP}")"
echo

# 1. Build + push
echo "==> 1/4 Building app image..."
docker build -t "${IMAGE_REPO}:${IMAGE_TAG}" "${REPO_ROOT}"
echo "==> Pushing to GHCR..."
docker push "${IMAGE_REPO}:${IMAGE_TAG}"

# 2. Read secrets from .bootstrap-secrets (local) or prompt
PG_PASS=""
if [ -f "${REPO_ROOT}/.bootstrap-secrets/postgres_password" ]; then
    PG_PASS=$(cat "${REPO_ROOT}/.bootstrap-secrets/postgres_password")
fi
if [ -z "${PG_PASS}" ]; then
    echo "WARNING: .bootstrap-secrets/postgres_password not found."
    echo "  The DATABASE_URL secret on the server should still work from the last CI deploy."
    echo "  If not, re-run new-service.sh or set DATABASE_URL manually."
fi

DB_URL_1="postgresql://postgres:${PG_PASS}@haproxy-rishi-1:5432/${POSTGRES_DB}"
DB_URL_2="postgresql://postgres:${PG_PASS}@haproxy-rishi-2:5432/${POSTGRES_DB}"

deploy_to_server() {
    local SERVER_IP="$1"
    local DB_URL="$2"
    local SERVER_NAME="$3"

    echo "==> Deploying to ${SERVER_NAME} (${SERVER_IP})..."

    # SCP files
    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no -r \
        "${REPO_ROOT}/docker-compose.yml" \
        "${REPO_ROOT}/caddy/snippet.caddy.template" \
        "${REPO_ROOT}/scripts/ci/deploy-app.sh" \
        "${REPO_ROOT}/scripts/ci/run-migrations.sh" \
        "${REPO_ROOT}/migrations" \
        "${REPO_ROOT}/project.config" \
        "${DEPLOY_USER}@${SERVER_IP}:/home/${DEPLOY_USER}/${PROJECT_REPO}/"

    # Run deploy-app.sh
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${DEPLOY_USER}@${SERVER_IP}" \
        "cd /home/${DEPLOY_USER}/${PROJECT_REPO} && \
         export IMAGE_TAG='${IMAGE_TAG}' && \
         export DATABASE_URL='${DB_URL}' && \
         export SENTRY_DSN='' && \
         export GITHUB_TOKEN='unused' && \
         export GITHUB_ACTOR='manual' && \
         export APP_DIR='/home/${DEPLOY_USER}/${PROJECT_REPO}' && \
         chmod +x scripts/ci/deploy-app.sh && \
         bash scripts/ci/deploy-app.sh"
}

# 3. Deploy to rishi-1 (canary)
deploy_to_server "${SERVER_1_IP}" "${DB_URL_1}" "rishi-1 (canary)"

# 4. Deploy to rishi-2 (only if canary succeeded and not --server-1-only)
if [ "${SERVER_1_ONLY}" = "false" ]; then
    deploy_to_server "${SERVER_2_IP}" "${DB_URL_2}" "rishi-2"
fi

echo
echo "==> Manual deploy complete."
echo "    Verify: curl https://${PROJECT_DOMAIN}/"
