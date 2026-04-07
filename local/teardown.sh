#!/bin/bash
# Stop the local stack and wipe all data volumes (so the next setup
# starts from a fresh bootstrap).
#
# Usage: bash local/teardown.sh

set -e

# Resolve repo root and source project.config so docker compose can interpolate
# the same ${VAR}s used in local/docker-compose.yml. Without this, `docker
# compose down -v` fails with "variable is not set" warnings and may not
# remove the right network.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
set -a
source "${REPO_ROOT}/project.config"
set +a
export IMAGE_TAG=local

cd "${SCRIPT_DIR}"

echo "==> Stopping all containers and removing volumes..."
docker compose down -v

echo ""
echo "==> Removing local secrets..."
rm -rf secrets

echo ""
echo "✅ Local stack torn down. Run bash local/setup.sh to start fresh."
