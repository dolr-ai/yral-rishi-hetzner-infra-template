#!/bin/bash
# =============================================================================
# LEGACY — use scripts/add-server.sh instead.
#
# add-server.sh does everything this script does but is generic (takes
# --name and --ip as args) and reads from servers.config instead of
# hardcoding the IP. This file is kept only for historical reference.
#
# Original purpose: ONE-TIME SETUP for rishi-3 (136.243.147.225)
# Run from your Mac ONCE before the first deploy:
#   bash scripts/rishi3-setup.sh
#
# PREREQUISITE: SSH access to root@136.243.147.225
#
# What this script does on rishi-3:
# 1. Creates the "deploy" non-root user (CI never runs as root)
# 2. Adds the CI SSH key to deploy's authorized_keys
# 3. Adds deploy to the docker group (so it can run docker commands)
# 4. Creates the shared Docker "web" network (needed for Caddy/app)
# 5. Creates necessary directories for CI to deploy into
#
# NOTE: Firewall rules for inter-server ports (etcd, Patroni) are handled
# by the Docker Swarm overlay network (db-internal). No UFW rules needed
# for application ports — that's the whole point of the overlay approach.
# Swarm infrastructure ports (2377, 7946, 4789) are opened by swarm-setup.sh.
# =============================================================================

set -e

RISHI_3_IP="136.243.147.225"
CI_PUBLIC_KEY=$(cat ~/.ssh/rishi-hetzner-ci-key.pub)

echo "Setting up rishi-3 ($RISHI_3_IP) as a database server..."
echo ""

ssh root@"${RISHI_3_IP}" bash <<REMOTE
set -e

echo "==> Creating deploy user..."
if id deploy &>/dev/null; then
    echo "    deploy user already exists, skipping"
else
    useradd --create-home --shell /bin/bash deploy
    echo "    deploy user created"
fi

echo "==> Adding CI SSH key to deploy user..."
mkdir -p /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
if ! grep -qF "${CI_PUBLIC_KEY}" /home/deploy/.ssh/authorized_keys 2>/dev/null; then
    echo "${CI_PUBLIC_KEY}" >> /home/deploy/.ssh/authorized_keys
    echo "    CI key added"
else
    echo "    CI key already present, skipping"
fi
chmod 600 /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh

echo "==> Adding deploy to docker group..."
usermod -aG docker deploy
echo "    done (takes effect on next login)"

echo "==> Creating Docker web network (if not exists)..."
docker network create web 2>/dev/null && echo "    web network created" \
    || echo "    web network already exists, skipping"

echo "==> Creating deployment directories..."
mkdir -p /home/deploy/etcd
mkdir -p /home/deploy/patroni
chown -R deploy:deploy /home/deploy/etcd /home/deploy/patroni
echo "    directories created"

echo ""
echo "============================================"
echo " rishi-3 setup complete!"
echo " Run scripts/swarm-setup.sh next to join"
echo " this server to the Docker Swarm cluster."
echo "============================================"
REMOTE

echo ""
echo "Verifying SSH as deploy user..."
ssh -o ConnectTimeout=10 deploy@"${RISHI_3_IP}" "echo '    SSH as deploy: SUCCESS'" || \
    echo "    SSH as deploy failed — you may need to log out and back in for group changes to take effect"

echo ""
echo "========================================================"
echo " All done! rishi-3 is ready."
echo " Next step: bash scripts/swarm-setup.sh"
echo "========================================================"
