#!/bin/bash
# =============================================================================
# add-server.sh — generic "add a new Hetzner box to our cluster" bootstrap.
#
# Use this whenever you provision a new bare-metal server (rishi-4, rishi-5,
# etc.) and want it to join the existing Docker Swarm cluster.
#
# What it does (idempotent — safe to re-run):
#   1. Creates the non-root `deploy` user on the new server (root SSH needed)
#   2. Installs the CI SSH public key into deploy's authorized_keys
#   3. Adds deploy to the docker group
#   4. Opens UFW ports for Docker Swarm (2377/tcp, 7946 tcp+udp, 4789/udp)
#   5. Creates the shared `web` Docker network (used by Caddy + apps)
#   6. Creates standard deployment directories under /home/deploy/
#   7. Joins the new server to the existing Docker Swarm as a worker
#   8. Adds a node label `server=<name>` so stack files can pin to it
#   9. Appends the new server to servers.config (so future deploys see it)
#
# Usage:
#   bash scripts/add-server.sh --name rishi-4 --ip 5.6.7.8
#   bash scripts/add-server.sh --name rishi-4 --ip 5.6.7.8 --as-manager
#
# PREREQUISITES:
#   - You can SSH as root to the new server (one-time, then never again)
#   - The CI SSH public key exists at ~/.ssh/rishi-hetzner-ci-key.pub
#   - The existing Swarm manager (SERVER_1_IP in servers.config) is reachable
#     as the deploy user
#
# AFTER RUNNING:
#   - Verify: ssh deploy@<new-ip> "docker node ls" (you'll see the new node)
#   - To actually USE the new node for a service, edit that service's stack
#     files to reference `server=<name>` in placement constraints, or scale
#     the service to include it.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ----- Parse args -----
NAME=""
IP=""
AS_MANAGER="false"
while [ $# -gt 0 ]; do
    case "$1" in
        --name) NAME="$2"; shift 2 ;;
        --ip) IP="$2"; shift 2 ;;
        --as-manager) AS_MANAGER="true"; shift ;;
        -h|--help)
            sed -n '2,40p' "$0"
            exit 0 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

if [ -z "${NAME}" ] || [ -z "${IP}" ]; then
    echo "Usage: bash scripts/add-server.sh --name rishi-N --ip A.B.C.D [--as-manager]"
    exit 1
fi

# ----- Load existing infra config -----
if [ ! -f "${REPO_ROOT}/servers.config" ]; then
    echo "FATAL: ${REPO_ROOT}/servers.config not found."
    exit 1
fi
set -a
source "${REPO_ROOT}/servers.config"
set +a

CI_PUBKEY_PATH="${SSH_KEY_PATH%.*}.pub"
# Expand the ~ that servers.config stores literally
CI_PUBKEY_PATH="${CI_PUBKEY_PATH/#\~/$HOME}"
if [ ! -f "${CI_PUBKEY_PATH}" ]; then
    echo "FATAL: CI public key not found at ${CI_PUBKEY_PATH}"
    echo "       (derived from SSH_KEY_PATH=${SSH_KEY_PATH} in servers.config)"
    exit 1
fi
CI_PUBKEY=$(cat "${CI_PUBKEY_PATH}")

MANAGER_IP="${SERVER_1_IP}"

echo "==> Adding server"
echo "    name:        ${NAME}"
echo "    ip:          ${IP}"
echo "    as manager:  ${AS_MANAGER}"
echo "    swarm mgr:   ${MANAGER_IP}"
echo ""

# ----- Step 1: provision deploy user + UFW + web network on the new box -----
echo "==> 1/4 Provisioning deploy user, UFW, web network on ${IP} (root SSH)..."

ssh -o StrictHostKeyChecking=accept-new root@"${IP}" CI_PUBKEY="${CI_PUBKEY}" bash <<'REMOTE'
set -e

# 1a. deploy user
if id deploy &>/dev/null; then
    echo "    deploy user exists (skip)"
else
    useradd --create-home --shell /bin/bash deploy
    echo "    deploy user created"
fi

# 1b. CI public key
mkdir -p /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
if ! grep -qF "${CI_PUBKEY}" /home/deploy/.ssh/authorized_keys 2>/dev/null; then
    echo "${CI_PUBKEY}" >> /home/deploy/.ssh/authorized_keys
    echo "    CI key installed"
else
    echo "    CI key already present (skip)"
fi
chmod 600 /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh

# 1c. docker group
if command -v docker &>/dev/null; then
    usermod -aG docker deploy
    echo "    deploy added to docker group"
else
    echo "    WARN: docker not installed on this server. Install Docker first."
    exit 1
fi

# 1d. UFW ports for Swarm
if command -v ufw &>/dev/null; then
    ufw allow 2377/tcp comment "Docker Swarm management" >/dev/null
    ufw allow 7946/tcp comment "Docker Swarm node discovery TCP" >/dev/null
    ufw allow 7946/udp comment "Docker Swarm node discovery UDP" >/dev/null
    ufw allow 4789/udp comment "Docker Swarm VXLAN overlay" >/dev/null
    echo "    UFW Swarm ports opened"
else
    echo "    WARN: ufw not installed; skipping firewall step"
fi

# 1e. shared web network (used by Caddy + per-service apps)
docker network inspect web >/dev/null 2>&1 \
    && echo "    web network exists (skip)" \
    || { docker network create web >/dev/null && echo "    web network created"; }

# 1f. standard dirs
mkdir -p /home/deploy/etcd /home/deploy/patroni /home/deploy/caddy/conf.d
chown -R deploy:deploy /home/deploy/etcd /home/deploy/patroni /home/deploy/caddy
echo "    deploy dirs ready"
REMOTE

echo ""

# ----- Step 2: verify deploy SSH works -----
echo "==> 2/4 Verifying deploy SSH..."
ssh -i "${SSH_KEY_PATH/#\~/$HOME}" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    deploy@"${IP}" 'echo "    deploy@$(hostname) ssh OK"'

echo ""

# ----- Step 3: join the swarm -----
echo "==> 3/4 Joining Docker Swarm..."

if [ "${AS_MANAGER}" = "true" ]; then
    JOIN_TOKEN=$(ssh -i "${SSH_KEY_PATH/#\~/$HOME}" deploy@"${MANAGER_IP}" \
        "docker swarm join-token manager -q")
else
    JOIN_TOKEN=$(ssh -i "${SSH_KEY_PATH/#\~/$HOME}" deploy@"${MANAGER_IP}" \
        "docker swarm join-token worker -q")
fi

ssh -i "${SSH_KEY_PATH/#\~/$HOME}" deploy@"${IP}" \
    "docker swarm join --token ${JOIN_TOKEN} ${MANAGER_IP}:2377 2>/dev/null \
        && echo '    joined as ${AS_MANAGER:+manager}${AS_MANAGER:-worker}' \
        || echo '    already in swarm (skip)'"

# Get the new node's ID and label it
NODE_ID=$(ssh -i "${SSH_KEY_PATH/#\~/$HOME}" deploy@"${MANAGER_IP}" \
    "docker node ls --format '{{.ID}} {{.Hostname}}' | awk -v ip='${IP}' '\$2 == \"${NAME}\" || \$2 ~ /./ {print \$1; exit}' " || true)

# Safer node lookup: match by self.Addr from the new server
NODE_ID=$(ssh -i "${SSH_KEY_PATH/#\~/$HOME}" deploy@"${IP}" \
    "docker info --format '{{.Swarm.NodeID}}'")

ssh -i "${SSH_KEY_PATH/#\~/$HOME}" deploy@"${MANAGER_IP}" \
    "docker node update --label-add server=${NAME} ${NODE_ID}" >/dev/null
echo "    labeled node ${NODE_ID} with server=${NAME}"

echo ""

# ----- Step 4: append to servers.config -----
echo "==> 4/4 Updating servers.config..."

# Find the next free SERVER_N_IP slot
N=1
while grep -q "^SERVER_${N}_IP=" "${REPO_ROOT}/servers.config"; do
    N=$((N+1))
done

cat >> "${REPO_ROOT}/servers.config" <<EOF

# Added by add-server.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ): ${NAME}
SERVER_${N}_IP=${IP}
EOF

echo "    added SERVER_${N}_IP=${IP}"

echo ""
echo "========================================================"
echo " ${NAME} (${IP}) is now part of the Swarm cluster."
echo ""
echo " Verify:"
echo "   ssh deploy@${MANAGER_IP} 'docker node ls'"
echo ""
echo " Next:"
echo "   - Commit servers.config so CI sees the new server"
echo "   - To run app/DB on this node, edit the relevant stack files"
echo "     and add a placement constraint: server == ${NAME}"
echo "   - Tell Saikat about the new server so Beszel monitoring picks it up"
echo "========================================================"
