#!/bin/bash
# =============================================================================
# ONE-TIME Docker Swarm setup — run from your Mac ONCE using root SSH.
#
# This script does 5 things:
#   1. Opens Swarm infrastructure ports on all 3 servers (UFW)
#   2. Initializes Docker Swarm on rishi-1 (the manager)
#   3. Joins rishi-2 and rishi-3 as worker nodes
#   4. Adds node labels (server=rishi-1/2/3) for placement constraints
#   5. Creates the db-internal overlay network
#
# Usage: bash scripts/swarm-setup.sh
#
# WHY root SSH here but not in CI?
# Opening UFW ports requires root. This is ONE-TIME infra setup.
# After this, all future deployments use the deploy user via CI — no root needed.
# =============================================================================

set -e

RISHI_1="138.201.137.181"
RISHI_2="136.243.150.84"
RISHI_3="136.243.147.225"

echo "==> Step 1: Opening Swarm infrastructure ports on all 3 servers..."
echo "    TCP 2377 = Swarm management, TCP/UDP 7946 = node discovery, UDP 4789 = VXLAN overlay"

for SERVER in $RISHI_1 $RISHI_2 $RISHI_3; do
    echo "    Opening ports on ${SERVER}..."
    ssh root@"${SERVER}" bash <<'REMOTE'
ufw allow 2377/tcp comment "Docker Swarm management"
ufw allow 7946/tcp comment "Docker Swarm node discovery TCP"
ufw allow 7946/udp comment "Docker Swarm node discovery UDP"
ufw allow 4789/udp comment "Docker Swarm VXLAN overlay"
echo "    Done. Swarm ports now open:"
ufw status | grep -E "2377|7946|4789"
REMOTE
done

echo ""
echo "==> Step 2: Initializing Docker Swarm on rishi-1 (manager)..."
WORKER_TOKEN=$(ssh root@"${RISHI_1}" bash <<'REMOTE'
docker swarm init --advertise-addr 138.201.137.181 2>/dev/null || true
docker swarm join-token worker -q
REMOTE
)

echo "    Swarm initialized on rishi-1. Worker token captured."

echo ""
echo "==> Step 3: Joining rishi-2 and rishi-3 as worker nodes..."
ssh deploy@"${RISHI_2}" "docker swarm join --token ${WORKER_TOKEN} 138.201.137.181:2377 2>/dev/null && echo '    rishi-2 joined' || echo '    rishi-2: already in swarm'"
ssh deploy@"${RISHI_3}" "docker swarm join --token ${WORKER_TOKEN} 138.201.137.181:2377 2>/dev/null && echo '    rishi-3 joined' || echo '    rishi-3: already in swarm'"

echo ""
echo "==> Step 4: Adding node labels for placement constraints..."
echo "    WHY labels? stack.yml uses 'node.labels.server == rishi-X' to pin"
echo "    each etcd/Patroni container to its specific server. Without labels,"
echo "    Swarm could put rishi-1's etcd on rishi-2, breaking the cluster."

ssh root@"${RISHI_1}" bash <<'REMOTE'
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
echo "    rishi-2 is 136.243.150.84, rishi-3 is 136.243.147.225."
echo "    If they look swapped, fix with:"
echo "    ssh root@${RISHI_1} 'docker node update --label-add server=rishi-2 <id>'"

echo ""
echo "==> Step 5: Creating db-internal overlay network..."
ssh deploy@"${RISHI_1}" \
    "docker network create --driver overlay --attachable db-internal 2>/dev/null \
    && echo '    db-internal network created' \
    || echo '    db-internal already exists, skipping'"

echo ""
echo "========================================================"
echo " Swarm setup complete!"
echo ""
echo " Next verification steps:"
echo "   ssh deploy@${RISHI_1} 'docker node ls'"
echo "   (All 3 nodes should show Ready/Active)"
echo ""
echo "   ssh deploy@${RISHI_1} 'docker network ls | grep db-internal'"
echo "   (Should show the overlay network)"
echo "========================================================"
