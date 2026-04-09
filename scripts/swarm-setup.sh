#!/bin/bash
# =============================================================================
# ONE-TIME Docker Swarm setup — run from your Mac ONCE using root SSH.
#
# Reads server IPs from servers.config (NOT hardcoded). If you migrate to
# new servers, just update servers.config and re-run this script.
#
# This script does 5 things:
#   1. Opens Swarm infrastructure ports on all 3 servers (UFW)
#   2. Initializes Docker Swarm on Server 1 (the manager)
#   3. Joins Server 2 and Server 3 as worker nodes
#   4. Adds node labels (server=rishi-1/2/3) for placement constraints
#   5. Creates the shared `web` Docker network on each server
#
# Usage: bash scripts/swarm-setup.sh
#
# WHY root SSH here but not in CI?
# Opening UFW ports requires root. This is ONE-TIME infra setup.
# After this, all future deployments use the deploy user via CI — no root.
#
# PREREQUISITES:
#   - Root SSH access to all 3 servers (one-time only)
#   - servers.config exists with SERVER_1_IP, SERVER_2_IP, SERVER_3_IP
#   - The deploy user already exists on each server (run add-server.sh first
#     if provisioning from scratch, or the legacy rishi3-setup.sh)
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load server IPs from servers.config — the single source of truth
if [ ! -f "${REPO_ROOT}/servers.config" ]; then
    echo "FATAL: servers.config not found at ${REPO_ROOT}/servers.config"
    exit 1
fi
set -a
# shellcheck disable=SC1091
source "${REPO_ROOT}/servers.config"
set +a

# Expand ~ in SSH key path
SSH_KEY="${SSH_KEY_PATH/#\~/$HOME}"

MANAGER_IP="${SERVER_1_IP}"
WORKER_2_IP="${SERVER_2_IP}"
WORKER_3_IP="${SERVER_3_IP}"

echo "==> Swarm setup using servers from servers.config:"
echo "    Manager (rishi-1): ${MANAGER_IP}"
echo "    Worker  (rishi-2): ${WORKER_2_IP}"
echo "    Worker  (rishi-3): ${WORKER_3_IP}"
echo ""

echo "==> Step 1: Opening Swarm infrastructure ports on all 3 servers..."
echo "    TCP 2377 = Swarm management, TCP/UDP 7946 = node discovery, UDP 4789 = VXLAN overlay"

for SERVER in ${MANAGER_IP} ${WORKER_2_IP} ${WORKER_3_IP}; do
    echo "    Opening ports on ${SERVER}..."
    ssh root@"${SERVER}" bash <<'REMOTE'
ufw allow 2377/tcp comment "Docker Swarm management"
ufw allow 7946/tcp comment "Docker Swarm node discovery TCP"
ufw allow 7946/udp comment "Docker Swarm node discovery UDP"
ufw allow 4789/udp comment "Docker Swarm VXLAN overlay"
echo "    Done."
REMOTE
done

echo ""
echo "==> Step 2: Initializing Docker Swarm on the manager (${MANAGER_IP})..."
WORKER_TOKEN=$(ssh root@"${MANAGER_IP}" bash <<REMOTE
docker swarm init --advertise-addr ${MANAGER_IP} 2>/dev/null || true
docker swarm join-token worker -q
REMOTE
)

echo "    Swarm initialized. Worker token captured."

echo ""
echo "==> Step 3: Joining workers to the Swarm..."
ssh "${DEPLOY_USER}@${WORKER_2_IP}" \
    "docker swarm join --token ${WORKER_TOKEN} ${MANAGER_IP}:2377 2>/dev/null \
        && echo '    rishi-2 joined' \
        || echo '    rishi-2: already in swarm'"
ssh "${DEPLOY_USER}@${WORKER_3_IP}" \
    "docker swarm join --token ${WORKER_TOKEN} ${MANAGER_IP}:2377 2>/dev/null \
        && echo '    rishi-3 joined' \
        || echo '    rishi-3: already in swarm'"

echo ""
echo "==> Step 4: Adding node labels for placement constraints..."
echo "    WHY labels? stack.yml files use 'node.labels.server == rishi-X' to pin"
echo "    each etcd/Patroni container to its specific server. Without labels,"
echo "    Swarm could put rishi-1's etcd on rishi-2, breaking the cluster."
echo ""
echo "    Label names (rishi-1/2/3) are ARBITRARY — they're Docker metadata,"
echo "    NOT hostnames or IPs. If you migrate to new servers, just label the"
echo "    new nodes with the same names and everything works."

ssh root@"${MANAGER_IP}" bash <<'REMOTE'
# Get manager ID (that's rishi-1)
MANAGER_ID=$(docker node ls --format "{{.ID}} {{.ManagerStatus}}" | grep "Leader" | awk '{print $1}')

# Get worker IDs in join order (rishi-2 joined first, rishi-3 second)
mapfile -t WORKER_IDS < <(docker node ls --format "{{.ID}} {{.ManagerStatus}}" | grep -v "Leader" | awk '{print $1}')

echo "    Manager (rishi-1): ${MANAGER_ID}"
echo "    Worker 0 (rishi-2): ${WORKER_IDS[0]}"
echo "    Worker 1 (rishi-3): ${WORKER_IDS[1]}"

docker node update --label-add server=rishi-1 "${MANAGER_ID}"
docker node update --label-add server=rishi-2 "${WORKER_IDS[0]}"
docker node update --label-add server=rishi-3 "${WORKER_IDS[1]}"

echo ""
echo "    Cluster status after labeling:"
docker node ls
REMOTE

echo ""
echo "    IMPORTANT: Verify the labels are correct above."
echo "    rishi-2 is ${WORKER_2_IP}, rishi-3 is ${WORKER_3_IP}."
echo "    If they look swapped, fix with:"
echo "    ssh root@${MANAGER_IP} 'docker node update --label-add server=rishi-2 <id>'"

echo ""
echo "==> Step 5: Creating 'web' Docker network on each server..."
for SERVER in ${MANAGER_IP} ${WORKER_2_IP} ${WORKER_3_IP}; do
    ssh "${DEPLOY_USER}@${SERVER}" \
        "docker network inspect web >/dev/null 2>&1 \
            && echo '    ${SERVER}: web network exists (skip)' \
            || { docker network create web >/dev/null && echo '    ${SERVER}: web network created'; }"
done

echo ""
echo "========================================================"
echo " Swarm setup complete!"
echo ""
echo " Verification:"
echo "   ssh ${DEPLOY_USER}@${MANAGER_IP} 'docker node ls'"
echo "   (All 3 nodes should show Ready/Active)"
echo ""
echo " Next: push your service to GitHub and CI will deploy it."
echo "========================================================"
