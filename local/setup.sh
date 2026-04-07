#!/bin/bash
# Local setup: generate secrets, build images, start the full stack.
# After this, http://localhost:8080 serves the project's app.
#
# Usage: bash local/setup.sh

set -e

# Resolve the repo root from this script's location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Auto-export every variable from project.config so docker compose
# interpolates ${VAR} in local/docker-compose.yml AND so subsequent
# shell commands in this script see the same values.
set -a
source "${REPO_ROOT}/project.config"
set +a

# Local-only image tag (NOT the production git SHA)
export IMAGE_TAG=local

cd "${SCRIPT_DIR}"

echo "==> Project: ${PROJECT_NAME}"
echo "    PROJECT_REPO=${PROJECT_REPO}"
echo "    POSTGRES_DB=${POSTGRES_DB}"
echo "    PATRONI_SCOPE=${PATRONI_SCOPE}"
echo ""

echo "==> 1/4 Generating secrets (if missing)..."
mkdir -p secrets
chmod 700 secrets

if [ ! -f secrets/postgres_password ]; then
    openssl rand -hex 32 > secrets/postgres_password
    echo "    Created secrets/postgres_password"
else
    echo "    secrets/postgres_password already exists (reusing)"
fi

if [ ! -f secrets/replication_password ]; then
    openssl rand -hex 32 > secrets/replication_password
    echo "    Created secrets/replication_password"
else
    echo "    secrets/replication_password already exists (reusing)"
fi

# Always rewrite database_url so it picks up the current postgres_password and POSTGRES_DB
PG_PASS=$(cat secrets/postgres_password)
echo -n "postgresql://postgres:${PG_PASS}@haproxy:5432/${POSTGRES_DB}" > secrets/database_url
echo "    Wrote secrets/database_url (points to local haproxy:5432, db=${POSTGRES_DB})"

chmod 600 secrets/*

echo ""
echo "==> 2/4 Building images (app + Patroni) tagged as :local..."
echo "    Building with --network=host to fix Docker Desktop DNS issues during build"
echo "    Patroni image: ${PATRONI_IMAGE_REPO}:local"
docker build --network=host -t "${PATRONI_IMAGE_REPO}:local" "${REPO_ROOT}/patroni"
echo "    App image: ${IMAGE_REPO}:local"
docker build --network=host -t "${IMAGE_REPO}:local" "${REPO_ROOT}"

echo ""
echo "==> 3/4 Starting all services in detached mode..."
docker compose up -d

echo ""
echo "==> 4/4 Waiting for the cluster to converge (~45s for first bootstrap)..."
echo ""
for i in $(seq 1 30); do
    sleep 3
    HEALTH=$(curl -sf http://localhost:8080/health 2>/dev/null || echo "")
    if echo "$HEALTH" | grep -q '"status":"OK"'; then
        echo "    Cluster healthy after ${i} attempts."
        break
    fi
    printf "    [attempt %d/30] not ready yet, retrying in 3s...\r" "$i"
done
echo ""
echo ""

echo "========================================================"
HEALTH=$(curl -sf http://localhost:8080/health 2>/dev/null || echo "")
if echo "$HEALTH" | grep -q '"status":"OK"'; then
    echo "  ✅ Local stack is up and healthy (project: ${PROJECT_NAME})"
    echo ""
    echo "  Test the app:"
    echo "    curl http://localhost:8080/"
    echo ""
    echo "  Health check:"
    echo "    curl http://localhost:8080/health"
    echo ""
    echo "  Inspect the Patroni cluster:"
    echo "    docker exec patroni-rishi-1 patronictl -c /etc/patroni.yml list"
    echo "    (Should show 'Cluster: ${PATRONI_SCOPE}')"
    echo ""
    echo "  Tail logs:"
    echo "    docker compose -f local/docker-compose.yml logs -f"
    echo ""
    echo "  Stop and wipe everything:"
    echo "    bash local/teardown.sh"
else
    echo "  ⚠️  Stack came up but health check is not green yet."
    echo "  Run this to see what's wrong:"
    echo "    docker compose -f local/docker-compose.yml ps"
    echo "    docker compose -f local/docker-compose.yml logs --tail 50"
fi
echo "========================================================"
