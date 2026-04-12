#!/bin/bash
# ---------------------------------------------------------------------------
# swarm-setup.sh — ONE-TIME Docker Swarm cluster initialization.
#
# Run this ONCE from your Mac to turn 3 independent Hetzner servers into
# a Docker Swarm cluster that can run services across all of them.
#
# WHAT IS DOCKER SWARM?
# Docker Swarm is Docker's built-in clustering system. It lets you deploy
# containers across MULTIPLE servers from a single command. Without Swarm,
# you'd have to SSH into each server and run docker commands individually.
#
# WHAT DOES THIS SCRIPT DO? (5 steps)
#   1. Opens firewall ports on all 3 servers (so they can talk to each other)
#   2. Initializes Docker Swarm on Server 1 (makes it the "manager")
#   3. Joins Server 2 and Server 3 as "worker" nodes
#   4. Adds node labels (server=rishi-1/2/3) for placement constraints
#   5. Creates the "web" Docker network on each server (used by Caddy + apps)
#
# USAGE: bash scripts/swarm-setup.sh
#
# WHY ROOT SSH HERE BUT NOT IN CI?
# Opening firewall ports requires root access. This is a ONE-TIME setup.
# After this, all future deployments use the non-root "deploy" user via CI.
#
# PREREQUISITES:
#   - Root SSH access to all 3 servers (used only here, then never again)
#   - servers.config exists with SERVER_1_IP, SERVER_2_IP, SERVER_3_IP
#   - The deploy user already exists on each server
#
# AFTER RUNNING:
#   Push your service to GitHub and CI will deploy it to the cluster.
# ---------------------------------------------------------------------------

# "set -e" = stop the script immediately if ANY command fails.
set -e

# Figure out where THIS script lives on disk, and where the repo root is.
# "$(cd "$(dirname "$0")" && pwd)" resolves symlinks and gives an absolute path.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# The repo root is one directory up from scripts/
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ----- Load server IPs from servers.config -----
# servers.config is the SINGLE SOURCE OF TRUTH for server addresses.
# No IPs are hardcoded in this script.
if [ ! -f "${REPO_ROOT}/servers.config" ]; then
    echo "FATAL: servers.config not found at ${REPO_ROOT}/servers.config"
    exit 1
fi
# "set -a" = auto-export all variables (so they're available in SSH commands).
# "source" reads the file and loads KEY=value pairs into the shell.
# "set +a" = turn off auto-export.
set -a
# shellcheck disable=SC1091
source "${REPO_ROOT}/servers.config"
set +a

# Expand the ~ in the SSH key path to the actual home directory.
# servers.config stores "~/.ssh/..." but the shell needs "/Users/rishi/.ssh/..."
SSH_KEY="${SSH_KEY_PATH/#\~/$HOME}"

# Assign server IPs to descriptive variable names for clarity.
# Server 1 is the Swarm MANAGER (runs management commands).
# Servers 2 and 3 are WORKERS (run containers but don't manage the cluster).
MANAGER_IP="${SERVER_1_IP}"
WORKER_2_IP="${SERVER_2_IP}"
WORKER_3_IP="${SERVER_3_IP}"

# Print a summary of the servers we're setting up
echo "==> Swarm setup using servers from servers.config:"
echo "    Manager (rishi-1): ${MANAGER_IP}"
echo "    Worker  (rishi-2): ${WORKER_2_IP}"
echo "    Worker  (rishi-3): ${WORKER_3_IP}"
echo ""

# =====================================================================
# STEP 1: Open firewall ports for Docker Swarm on all 3 servers
# =====================================================================
echo "==> Step 1: Opening Swarm infrastructure ports on all 3 servers..."
echo "    TCP 2377 = Swarm management, TCP/UDP 7946 = node discovery, UDP 4789 = VXLAN overlay"

# Loop through all 3 server IPs
for SERVER in ${MANAGER_IP} ${WORKER_2_IP} ${WORKER_3_IP}; do
    echo "    Opening ports on ${SERVER}..."
    # SSH into the server as root and run UFW (Uncomplicated Firewall) commands.
    # "bash <<'REMOTE'" sends the following block as a script to the remote server.
    # Single-quoted 'REMOTE' prevents local variable expansion (not needed here).
    ssh root@"${SERVER}" bash <<'REMOTE'
# TCP 2377: Docker Swarm management traffic (cluster join/leave, stack deploy)
ufw allow 2377/tcp comment "Docker Swarm management"
# TCP 7946: Swarm node discovery and gossip protocol (how nodes find each other)
ufw allow 7946/tcp comment "Docker Swarm node discovery TCP"
# UDP 7946: Same discovery protocol over UDP (faster for heartbeats)
ufw allow 7946/udp comment "Docker Swarm node discovery UDP"
# UDP 4789: VXLAN overlay network traffic (encrypted data between containers
# on different servers — this is how the private overlay network works)
ufw allow 4789/udp comment "Docker Swarm VXLAN overlay"
echo "    Done."
REMOTE
done

echo ""

# =====================================================================
# STEP 2: Initialize Docker Swarm on the manager (rishi-1)
# =====================================================================
echo "==> Step 2: Initializing Docker Swarm on the manager (${MANAGER_IP})..."
# SSH into the manager as root and run the Swarm init command.
# "docker swarm init --advertise-addr" tells other nodes which IP to use
# to reach this manager. "2>/dev/null || true" suppresses the error if
# Swarm is already initialized (idempotent).
# Then get the WORKER join token (a secret string that authorizes new nodes).
WORKER_TOKEN=$(ssh root@"${MANAGER_IP}" bash <<REMOTE
docker swarm init --advertise-addr ${MANAGER_IP} 2>/dev/null || true
docker swarm join-token worker -q
REMOTE
)

echo "    Swarm initialized. Worker token captured."

echo ""

# =====================================================================
# STEP 3: Join worker nodes to the Swarm
# =====================================================================
echo "==> Step 3: Joining workers to the Swarm (with retry)..."

# Helper function: join a single worker to the Swarm with up to 5 retries.
# Docker Swarm join can occasionally fail due to timing issues, so we retry.
join_worker() {
    local WORKER_IP="$1"     # The worker's IP address
    local WORKER_NAME="$2"   # The worker's friendly name (e.g., "rishi-2")
    # Try up to 5 times
    for attempt in 1 2 3 4 5; do
        # "docker swarm join --token <token> <manager-ip>:2377" tells Docker
        # on the worker to join the Swarm cluster using the token from Step 2.
        if ssh "${DEPLOY_USER}@${WORKER_IP}" \
            "docker swarm join --token ${WORKER_TOKEN} ${MANAGER_IP}:2377 2>/dev/null"; then
            echo "    ${WORKER_NAME} joined (attempt ${attempt})"
            return 0
        fi
        # Check if the worker is ALREADY in the Swarm (not an error — just skip).
        # "docker info" reports the local node's Swarm state.
        if ssh "${DEPLOY_USER}@${WORKER_IP}" "docker info --format '{{.Swarm.LocalNodeState}}'" 2>/dev/null | grep -q active; then
            echo "    ${WORKER_NAME}: already in swarm"
            return 0
        fi
        echo "    ${WORKER_NAME}: join attempt ${attempt}/5 failed, retrying in 5s..."
        sleep 5
    done
    # All 5 attempts failed — something is seriously wrong
    echo "    FATAL: ${WORKER_NAME} (${WORKER_IP}) could not join the Swarm after 5 attempts"
    exit 1
}
# Join both workers
join_worker "${WORKER_2_IP}" "rishi-2"
join_worker "${WORKER_3_IP}" "rishi-3"

echo ""

# =====================================================================
# STEP 4: Add node labels for placement constraints
# =====================================================================
echo "==> Step 4: Adding node labels for placement constraints..."
echo "    WHY labels? stack.yml files use 'node.labels.server == rishi-X' to pin"
echo "    each etcd/Patroni container to its specific server. Without labels,"
echo "    Swarm could put rishi-1's etcd on rishi-2, breaking the cluster."
echo ""
echo "    Label names (rishi-1/2/3) are ARBITRARY — they're Docker metadata,"
echo "    NOT hostnames or IPs. If you migrate to new servers, just label the"
echo "    new nodes with the same names and everything works."

# SSH into the manager to add labels to each node.
# Labels are key-value pairs attached to Swarm nodes.
# Stack files reference these labels in placement constraints.
ssh root@"${MANAGER_IP}" bash <<'REMOTE'
# Find the manager node's ID. The manager has "Leader" in the ManagerStatus column.
# "docker node ls" lists all nodes in the Swarm.
# We filter for "Leader" to find the manager (rishi-1).
MANAGER_ID=$(docker node ls --format "{{.ID}} {{.ManagerStatus}}" | grep "Leader" | awk '{print $1}')

# Find worker node IDs. Workers don't have a ManagerStatus, so they're
# the lines WITHOUT "Leader". mapfile reads each line into an array.
mapfile -t WORKER_IDS < <(docker node ls --format "{{.ID}} {{.ManagerStatus}}" | grep -v "Leader" | awk '{print $1}')

# Print the IDs for verification
echo "    Manager (rishi-1): ${MANAGER_ID}"
echo "    Worker 0 (rishi-2): ${WORKER_IDS[0]}"
echo "    Worker 1 (rishi-3): ${WORKER_IDS[1]}"

# Add the "server" label to each node.
# "docker node update --label-add key=value <node-id>" sets the label.
docker node update --label-add server=rishi-1 "${MANAGER_ID}"
docker node update --label-add server=rishi-2 "${WORKER_IDS[0]}"
docker node update --label-add server=rishi-3 "${WORKER_IDS[1]}"

echo ""
echo "    Cluster status after labeling:"
# Print the full node list to verify everything looks correct
docker node ls
REMOTE

echo ""
# Print a warning about verifying labels are correct.
# Workers join in order, so rishi-2 SHOULD be WORKER_IDS[0], but if the
# servers joined in a different order, the labels could be swapped.
echo "    IMPORTANT: Verify the labels are correct above."
echo "    rishi-2 is ${WORKER_2_IP}, rishi-3 is ${WORKER_3_IP}."
echo "    If they look swapped, fix with:"
echo "    ssh root@${MANAGER_IP} 'docker node update --label-add server=rishi-2 <id>'"

echo ""

# =====================================================================
# STEP 5: Create the "web" Docker network on each server
# =====================================================================
echo "==> Step 5: Creating 'web' Docker network on each server..."
# The "web" network is a local bridge network used by Caddy (reverse proxy)
# and app containers to communicate ON EACH SERVER. It's NOT an overlay
# network (it doesn't span servers) — each server has its own "web" network.
for SERVER in ${MANAGER_IP} ${WORKER_2_IP} ${WORKER_3_IP}; do
    # Check if the network already exists (skip if so), otherwise create it.
    # "docker network inspect web" returns 0 if it exists, non-zero if not.
    ssh "${DEPLOY_USER}@${SERVER}" \
        "docker network inspect web >/dev/null 2>&1 \
            && echo '    ${SERVER}: web network exists (skip)' \
            || { docker network create web >/dev/null && echo '    ${SERVER}: web network created'; }"
done

# Print the final success message with verification instructions
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
