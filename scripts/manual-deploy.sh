#!/bin/bash
# ---------------------------------------------------------------------------
# manual-deploy.sh — EMERGENCY deploy that bypasses GitHub Actions.
#
# WHEN TO USE:
# ONLY when GitHub Actions is down and you need to push a hotfix.
# Normal deploys should ALWAYS go through CI (just push to main).
#
# WHAT IT DOES (same steps as CI, but run from YOUR Mac):
#   1. Builds the app Docker image locally
#   2. Pushes the image to GHCR (GitHub Container Registry)
#   3. SCPs (copies) files to each server via SSH
#   4. Runs deploy-app.sh on rishi-1 first (canary), then rishi-2
#
# PREREQUISITES:
#   - Docker running on your Mac
#   - gh auth status → logged in
#   - ~/.ssh/rishi-hetzner-ci-key accessible
#   - GHCR push access (docker login ghcr.io)
#
# USAGE:
#   bash scripts/manual-deploy.sh                    # deploy current code
#   bash scripts/manual-deploy.sh --tag abc123       # deploy a specific commit
#   bash scripts/manual-deploy.sh --server-1-only    # deploy to rishi-1 only
# ---------------------------------------------------------------------------

# Strict error handling:
#   -e = stop on any error
#   -u = treat unset variables as errors
#   -o pipefail = if any command in a pipe fails, the whole pipe fails
set -euo pipefail

# Find the directory this script is in, then the project root (one level up)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load ALL config variables from project.config and servers.config
# "set -a" = auto-export (so child processes like docker see them)
set -a
source "${REPO_ROOT}/project.config"
source "${REPO_ROOT}/servers.config"
set +a

# Expand the ~ in SSH_KEY_PATH to the actual home directory path
# "${SSH_KEY_PATH/#\~/$HOME}" means "replace ~ at the start with $HOME"
SSH_KEY="${SSH_KEY_PATH/#\~/$HOME}"

# Initialize variables for command-line arguments
IMAGE_TAG=""           # which image version to deploy (default: current git commit)
SERVER_1_ONLY="false"  # whether to skip rishi-2

# ----- PARSE COMMAND-LINE ARGUMENTS -----
# "$#" is the number of arguments. "while [ $# -gt 0 ]" loops until all are processed.
# "case" matches each argument against patterns.
# "shift" removes the processed argument(s) from the list.
while [ $# -gt 0 ]; do
    case "$1" in
        --tag) IMAGE_TAG="$2"; shift 2 ;;           # next arg is the tag value
        --server-1-only) SERVER_1_ONLY="true"; shift ;; # no value needed
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;   # print lines 2-20 of this script (usage)
        *) echo "Unknown arg: $1"; exit 1 ;;         # anything else = error
    esac
done

# If no --tag was specified, use the current git commit SHA as the tag
# "git rev-parse HEAD" returns the full SHA of the latest commit (e.g., abc123def456...)
[ -z "${IMAGE_TAG}" ] && IMAGE_TAG=$(git -C "${REPO_ROOT}" rev-parse HEAD)

echo "==> MANUAL DEPLOY (bypassing CI)"
echo "    project: ${PROJECT_REPO}"
echo "    tag:     ${IMAGE_TAG}"
echo "    servers: ${SERVER_1_IP}$([ "${SERVER_1_ONLY}" = "false" ] && echo " + ${SERVER_2_IP}")"
echo

# ----- STEP 1: Build the Docker image locally and push to GHCR -----
echo "==> 1/4 Building app image..."
# "docker build -t NAME:TAG PATH" builds an image from the Dockerfile at PATH
docker build -t "${IMAGE_REPO}:${IMAGE_TAG}" "${REPO_ROOT}"
echo "==> Pushing to GHCR..."
# "docker push" uploads the image to the registry (GHCR)
docker push "${IMAGE_REPO}:${IMAGE_TAG}"

# ----- STEP 2: Read the database password -----
# Try to read from the local .bootstrap-secrets directory
# (created by new-service.sh during initial setup)
PG_PASS=""
if [ -f "${REPO_ROOT}/.bootstrap-secrets/postgres_password" ]; then
    PG_PASS=$(cat "${REPO_ROOT}/.bootstrap-secrets/postgres_password")
fi
if [ -z "${PG_PASS}" ]; then
    echo "WARNING: .bootstrap-secrets/postgres_password not found."
    echo "  The DATABASE_URL secret on the server should still work from the last CI deploy."
    echo "  If not, re-run new-service.sh or set DATABASE_URL manually."
fi

# Compose the DATABASE_URL for each server
# These URLs tell the app WHERE the database is and HOW to authenticate
DB_URL_1="postgresql://postgres:${PG_PASS}@haproxy-rishi-1:5432/${POSTGRES_DB}"
DB_URL_2="postgresql://postgres:${PG_PASS}@haproxy-rishi-2:5432/${POSTGRES_DB}"

# ----- DEPLOY FUNCTION -----
# This function deploys to ONE server. It's called twice (once per server).
# "local" makes variables function-scoped (don't leak to the rest of the script)
deploy_to_server() {
    local SERVER_IP="$1"     # first argument: the server's IP address
    local DB_URL="$2"        # second argument: the database URL for this server
    local SERVER_NAME="$3"   # third argument: a human-readable name (for logs)

    echo "==> Deploying to ${SERVER_NAME} (${SERVER_IP})..."

    # SCP: Secure Copy Protocol — copies files from your Mac to the server via SSH.
    # "-i" = use this SSH key
    # "-o StrictHostKeyChecking=no" = don't ask "are you sure?" for new servers
    # "-r" = recursive (copy directories too, not just files)
    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no -r \
        "${REPO_ROOT}/docker-compose.yml" \
        "${REPO_ROOT}/caddy/snippet.caddy.template" \
        "${REPO_ROOT}/scripts/ci/deploy-app.sh" \
        "${REPO_ROOT}/scripts/ci/run-migrations.sh" \
        "${REPO_ROOT}/migrations" \
        "${REPO_ROOT}/project.config" \
        "${DEPLOY_USER}@${SERVER_IP}:/home/${DEPLOY_USER}/${PROJECT_REPO}/"

    # SSH into the server and run the deploy script.
    # "export" sets environment variables that deploy-app.sh reads.
    # "chmod +x" makes the script executable (in case SCP reset permissions).
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

# ----- STEP 3: Deploy to rishi-1 (canary — goes first) -----
# If this fails, rishi-2 is never touched (canary pattern)
deploy_to_server "${SERVER_1_IP}" "${DB_URL_1}" "rishi-1 (canary)"

# ----- STEP 4: Deploy to rishi-2 (only if rishi-1 succeeded) -----
if [ "${SERVER_1_ONLY}" = "false" ]; then
    deploy_to_server "${SERVER_2_IP}" "${DB_URL_2}" "rishi-2"
fi

echo
echo "==> Manual deploy complete."
echo "    Verify: curl https://${PROJECT_DOMAIN}/"
