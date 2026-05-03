#!/bin/bash
# ---------------------------------------------------------------------------
# add-server.sh — add a new Hetzner bare-metal server to the Docker Swarm cluster.
#
# Use this whenever you provision a new server (rishi-4, rishi-5, etc.) and
# want it to join the existing cluster so you can run services on it.
#
# WHAT DOES THIS SCRIPT DO? (4 main steps)
#   1. PROVISION: Creates the "deploy" user on the new server, installs the
#      CI SSH key, opens firewall ports for Docker Swarm, and creates the
#      "web" Docker network used by Caddy + apps.
#   2. VERIFY: Tests that SSH works with the new deploy user.
#   3. JOIN SWARM: Gets a join token from the existing manager (rishi-1) and
#      uses it to join the new server to the Swarm cluster. Adds a node label
#      (e.g., server=rishi-4) so stack files can pin containers to it.
#   4. UPDATE CONFIG: Appends the new server's IP to servers.config so future
#      deploys and scripts know about it.
#
# IDEMPOTENT: safe to re-run (each step checks if work was already done).
#
# USAGE:
#   bash scripts/add-server.sh --name rishi-4 --ip 5.6.7.8
#   bash scripts/add-server.sh --name rishi-4 --ip 5.6.7.8 --as-manager
#
# PREREQUISITES:
#   - You can SSH as root to the new server (this is one-time, then never again)
#   - The CI SSH public key exists at ~/.ssh/rishi-hetzner-ci-key.pub
#   - The existing Swarm manager (SERVER_1_IP) is reachable as the deploy user
#
# AFTER RUNNING:
#   - Verify: ssh deploy@<new-ip> "docker node ls"
#   - To USE the new node for a service, edit that service's stack files
#     and add placement constraints referencing server=<name>
# ---------------------------------------------------------------------------

# "set -e" = stop the script immediately if ANY command fails.
# Without this, the script would keep running after errors, potentially
# making things worse.
set -e

# Figure out where THIS script lives on disk, and where the repo root is.
# "$(cd "$(dirname "$0")" && pwd)" resolves symlinks and gives an absolute path.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# The repo root is one directory up from scripts/
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ----- Parse command-line arguments -----
# Initialize all arguments as empty/default
NAME=""          # The name for the new server (e.g., "rishi-4")
IP=""            # The IP address of the new server
AS_MANAGER="false"  # Whether to join as a Swarm manager (default: worker)

# Loop through all arguments passed to the script.
# "$#" is the number of remaining arguments. "shift" removes one.
while [ $# -gt 0 ]; do
    case "$1" in
        # --name rishi-4 → sets NAME="rishi-4", then skips past both args
        --name) NAME="$2"; shift 2 ;;
        # --ip 5.6.7.8 → sets IP="5.6.7.8"
        --ip) IP="$2"; shift 2 ;;
        # --as-manager → join as a Swarm manager instead of a worker
        --as-manager) AS_MANAGER="true"; shift ;;
        # -h or --help → print the header comment block and exit
        -h|--help)
            # "sed -n '2,40p'" prints lines 2-40 of this file (the comment block)
            sed -n '2,40p' "$0"
            exit 0 ;;
        # Any unrecognized argument → print error and exit
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# Both --name and --ip are required. If either is missing, show usage and exit.
if [ -z "${NAME}" ] || [ -z "${IP}" ]; then
    echo "Usage: bash scripts/add-server.sh --name rishi-N --ip A.B.C.D [--as-manager]"
    exit 1
fi

# ----- Load existing infrastructure configuration -----
# servers.config contains SERVER_1_IP, DEPLOY_USER, SSH_KEY_PATH, etc.
if [ ! -f "${REPO_ROOT}/servers.config" ]; then
    echo "FATAL: ${REPO_ROOT}/servers.config not found."
    exit 1
fi
# "set -a" makes every variable assignment automatically exported (visible to child processes).
# "source" reads the file and executes each line (loading KEY=value pairs into the shell).
# "set +a" turns off auto-export.
set -a
source "${REPO_ROOT}/servers.config"
set +a

# Derive the public key path from the private key path.
# "${SSH_KEY_PATH%.*}" removes the file extension (e.g., "key" → "key" stays, but
# "key.pem" → "key"). Then we add ".pub" to get the public key path.
CI_PUBKEY_PATH="${SSH_KEY_PATH%.*}.pub"
# "${VAR/#\~/$HOME}" replaces a leading ~ with the actual home directory path.
# servers.config stores paths with ~ but the shell needs absolute paths.
CI_PUBKEY_PATH="${CI_PUBKEY_PATH/#\~/$HOME}"
# Make sure the public key file actually exists
if [ ! -f "${CI_PUBKEY_PATH}" ]; then
    echo "FATAL: CI public key not found at ${CI_PUBKEY_PATH}"
    echo "       (derived from SSH_KEY_PATH=${SSH_KEY_PATH} in servers.config)"
    exit 1
fi
# Read the public key contents into a variable (we'll paste it into authorized_keys)
CI_PUBKEY=$(cat "${CI_PUBKEY_PATH}")

# The Swarm manager is always Server 1 (the first server in the cluster)
MANAGER_IP="${SERVER_1_IP}"

# Print a summary of what we're about to do
echo "==> Adding server"
echo "    name:        ${NAME}"
echo "    ip:          ${IP}"
echo "    as manager:  ${AS_MANAGER}"
echo "    swarm mgr:   ${MANAGER_IP}"
echo ""

# ----- Step 1: Provision the new server (runs as root over SSH) -----
echo "==> 1/4 Provisioning deploy user, UFW, web network on ${IP} (root SSH)..."

# SSH into the new server as root. "CI_PUBKEY=${CI_PUBKEY}" passes the public key
# as an environment variable to the remote shell. "bash <<'REMOTE'" sends the
# following block as a script to execute on the remote server.
# 'REMOTE' (single-quoted) prevents local variable expansion — ${CI_PUBKEY} is
# expanded on the REMOTE side from the env var we passed.
ssh -o StrictHostKeyChecking=accept-new root@"${IP}" CI_PUBKEY="${CI_PUBKEY}" bash <<'REMOTE'
# Stop on any error inside the remote script too
set -e

# 1a. Create the "deploy" user (if it doesn't already exist).
# "deploy" is a non-root user that CI uses for all future SSH connections.
# Using a non-root user is a security best practice — it limits what CI can do.
if id deploy &>/dev/null; then
    echo "    deploy user exists (skip)"
else
    # --create-home: create /home/deploy/
    # --shell /bin/bash: use bash as the default shell
    useradd --create-home --shell /bin/bash deploy
    echo "    deploy user created"
fi

# 1b. Install the CI SSH public key so CI can SSH as the deploy user.
# "authorized_keys" lists which SSH keys are allowed to log in as this user.
mkdir -p /home/deploy/.ssh
# 700 = only the owner can read/write/enter this directory
chmod 700 /home/deploy/.ssh
# Check if the key is already installed (don't add duplicates)
# "grep -qF" = quiet (no output), Fixed string (not a regex)
if ! grep -qF "${CI_PUBKEY}" /home/deploy/.ssh/authorized_keys 2>/dev/null; then
    # Append the public key to the authorized_keys file
    echo "${CI_PUBKEY}" >> /home/deploy/.ssh/authorized_keys
    echo "    CI key installed"
else
    echo "    CI key already present (skip)"
fi
# 600 = only the owner can read/write this file (SSH requires strict permissions)
chmod 600 /home/deploy/.ssh/authorized_keys
# Make sure deploy owns all its SSH files (not root)
chown -R deploy:deploy /home/deploy/.ssh

# 1c. Add the deploy user to the "docker" group so it can run Docker commands
# without sudo. Docker commands require either root or docker group membership.
if command -v docker &>/dev/null; then
    usermod -aG docker deploy
    echo "    deploy added to docker group"
else
    echo "    WARN: docker not installed on this server. Install Docker first."
    exit 1
fi

# 1d. Open firewall (UFW) ports that Docker Swarm needs to communicate.
# UFW = Uncomplicated Firewall (the standard firewall on Ubuntu servers).
if command -v ufw &>/dev/null; then
    # TCP 2377: Swarm management traffic (join/leave cluster, deploy stacks)
    ufw allow 2377/tcp comment "Docker Swarm management" >/dev/null
    # TCP 7946: node discovery and gossip protocol (how nodes find each other)
    ufw allow 7946/tcp comment "Docker Swarm node discovery TCP" >/dev/null
    # UDP 7946: same discovery protocol but over UDP (faster for heartbeats)
    ufw allow 7946/udp comment "Docker Swarm node discovery UDP" >/dev/null
    # UDP 4789: VXLAN overlay network traffic (encrypted data between containers
    # on different servers)
    ufw allow 4789/udp comment "Docker Swarm VXLAN overlay" >/dev/null
    echo "    UFW Swarm ports opened"
else
    echo "    WARN: ufw not installed; skipping firewall step"
fi

# 1e. Create the "web" Docker network (used by Caddy reverse proxy + all app containers).
# "docker network inspect web" checks if it already exists.
# "&&" = if it exists, print skip message.
# "||" = if it doesn't exist, create it.
docker network inspect web >/dev/null 2>&1 \
    && echo "    web network exists (skip)" \
    || { docker network create web >/dev/null && echo "    web network created"; }

# 1f. Create standard directories that deploy scripts expect to exist.
# /home/deploy/etcd: etcd data directory
# /home/deploy/patroni: Patroni data directory
# /home/deploy/caddy/conf.d: Caddy per-project config snippets
mkdir -p /home/deploy/etcd /home/deploy/patroni /home/deploy/caddy/conf.d
# Make sure deploy owns these (not root)
chown -R deploy:deploy /home/deploy/etcd /home/deploy/patroni /home/deploy/caddy
echo "    deploy dirs ready"
REMOTE

echo ""

# ----- Step 1.5: Bootstrap Caddy on the new server -----
# Until 2026-05-03 this step did not exist and Caddy had to be installed
# manually after add-server.sh ran. The 2026-05-03 incident showed the
# cost of that manual step being skipped: rishi-3 was in the Cloudflare
# wildcard but had no Caddy → ~33% of CF probes silently dropped → 521s.
#
# What this step does:
#   - Copies caddy/render-caddy-compose.sh to the new server.
#   - Writes /home/deploy/caddy/Caddyfile (the master config that imports
#     every per-project snippet from conf.d/).
#   - Initializes an empty /home/deploy/caddy/.overlays-list. As services
#     deploy via deploy-app.sh / update-caddy-snippet.sh, they append
#     their overlay name and re-render the compose (idempotent).
#   - Runs render-caddy-compose.sh to generate docker-compose.yml and
#     bring Caddy up. Caddy starts with no per-project snippets and the
#     `web` bridge only — services add themselves on first deploy.
#
# After this step, the new server is reachable on :443 (with self-signed
# cert until a snippet is deployed for it). Add the server to CADDY_HOSTS
# (and APP_SERVERS if it should run app containers) so future CI deploys
# push snippets to it automatically.
echo "==> 1.5/4 Bootstrapping Caddy on ${IP}..."

# SCP the render helper into the new server's caddy directory.
scp -i "${SSH_KEY_PATH/#\~/$HOME}" -o StrictHostKeyChecking=accept-new \
    "${REPO_ROOT}/caddy/render-caddy-compose.sh" \
    deploy@"${IP}":/home/deploy/caddy/render-caddy-compose.sh

# SSH as deploy + write Caddyfile + chmod render helper + render initial
# compose + bring Caddy up. Single heredoc for atomicity.
ssh -i "${SSH_KEY_PATH/#\~/$HOME}" deploy@"${IP}" bash <<'BOOTSTRAP'
set -e
chmod 755 /home/deploy/caddy/render-caddy-compose.sh
cat > /home/deploy/caddy/Caddyfile <<'CADDYFILE'
# Imports every per-project snippet. Each project drops its snippet into
# /home/deploy/caddy/conf.d/<repo>.caddy via CI. Caddy reloads automatically
# on change. Do NOT add per-project blocks here directly.
import /etc/caddy/conf.d/*.caddy
CADDYFILE
touch /home/deploy/caddy/.overlays-list
/home/deploy/caddy/render-caddy-compose.sh
BOOTSTRAP

echo "    Caddy bootstrapped on ${NAME}"
echo ""

# ----- Step 2: Verify SSH works with the deploy user -----
echo "==> 2/4 Verifying deploy SSH..."
# Try to SSH as the deploy user using the CI private key.
# -i: use this specific private key
# -o ConnectTimeout=10: give up after 10 seconds
# -o StrictHostKeyChecking=accept-new: automatically trust the server's fingerprint
# The remote command just prints a success message with the hostname.
ssh -i "${SSH_KEY_PATH/#\~/$HOME}" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    deploy@"${IP}" 'echo "    deploy@$(hostname) ssh OK"'

echo ""

# ----- Step 3: Join the Docker Swarm cluster -----
echo "==> 3/4 Joining Docker Swarm..."

# Get a join token from the Swarm manager (rishi-1).
# The token is a secret string that authorizes new nodes to join.
# "docker swarm join-token <role> -q" outputs just the token (quiet mode).
if [ "${AS_MANAGER}" = "true" ]; then
    # Get a MANAGER join token (the new server will be a co-manager)
    JOIN_TOKEN=$(ssh -i "${SSH_KEY_PATH/#\~/$HOME}" deploy@"${MANAGER_IP}" \
        "docker swarm join-token manager -q")
else
    # Get a WORKER join token (the new server will be a worker)
    JOIN_TOKEN=$(ssh -i "${SSH_KEY_PATH/#\~/$HOME}" deploy@"${MANAGER_IP}" \
        "docker swarm join-token worker -q")
fi

# SSH into the new server and tell Docker to join the Swarm using the token.
# "docker swarm join --token <token> <manager-ip>:2377" joins the cluster.
# Port 2377 is the Swarm management port.
# "2>/dev/null" suppresses the "already in swarm" error message.
# "||" = if join fails (already in swarm), print skip message instead of error.
ssh -i "${SSH_KEY_PATH/#\~/$HOME}" deploy@"${IP}" \
    "docker swarm join --token ${JOIN_TOKEN} ${MANAGER_IP}:2377 2>/dev/null \
        && echo '    joined as ${AS_MANAGER:+manager}${AS_MANAGER:-worker}' \
        || echo '    already in swarm (skip)'"

# Get the new node's Swarm ID. Each node in the Swarm has a unique ID.
# We need it to add a label to the node.
# First attempt: try to find it from the manager's node list.
NODE_ID=$(ssh -i "${SSH_KEY_PATH/#\~/$HOME}" deploy@"${MANAGER_IP}" \
    "docker node ls --format '{{.ID}} {{.Hostname}}' | awk -v ip='${IP}' '\$2 == \"${NAME}\" || \$2 ~ /./ {print \$1; exit}' " || true)

# Safer approach: ask the new server directly for its own Swarm node ID.
# "docker info --format '{{.Swarm.NodeID}}'" prints the local node's ID.
NODE_ID=$(ssh -i "${SSH_KEY_PATH/#\~/$HOME}" deploy@"${IP}" \
    "docker info --format '{{.Swarm.NodeID}}'")

# Add a label to the new node. Labels are key-value pairs attached to Swarm nodes.
# Stack files use "node.labels.server == rishi-4" in placement constraints to
# pin specific containers to specific servers.
ssh -i "${SSH_KEY_PATH/#\~/$HOME}" deploy@"${MANAGER_IP}" \
    "docker node update --label-add server=${NAME} ${NODE_ID}" >/dev/null
echo "    labeled node ${NODE_ID} with server=${NAME}"

echo ""

# ----- Step 4: Append the new server to servers.config -----
echo "==> 4/4 Updating servers.config..."

# Find the next available SERVER_N_IP slot number.
# Loop: check if SERVER_1_IP exists, then SERVER_2_IP, etc.
# When we find a number that ISN'T in the file, that's our slot.
N=1
while grep -q "^SERVER_${N}_IP=" "${REPO_ROOT}/servers.config"; do
    N=$((N+1))
done

# Append the new server's IP to servers.config.
# "cat >> file <<EOF" = append everything between <<EOF and EOF to the file.
# This adds a comment with the date and the new SERVER_N_IP=<ip> line.
cat >> "${REPO_ROOT}/servers.config" <<EOF

# Added by add-server.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ): ${NAME}
SERVER_${N}_IP=${IP}
EOF

echo "    added SERVER_${N}_IP=${IP}"

# Print a summary of what was done and what to do next
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
