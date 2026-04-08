#!/bin/bash
# strip-database.sh — convert this template into a stateless service.
#
# Run ONCE, immediately after `scripts/init-from-template.sh`, when the new
# project does NOT need Postgres (e.g. stateless ML inference, webhook relay).
#
# What it does:
#   - Deletes etcd/, patroni/, haproxy/, scripts/swarm-setup.sh
#   - Removes db-internal network + database_url secret from docker-compose.yml
#   - Removes the local-dev DB tier (local/ uses single-host compose)
#   - Sets WITH_DATABASE=false in project.config (CI then skips deploy-db-stack)
#
# After running this, the new project's checklist of GitHub Secrets shrinks:
# no POSTGRES_PASSWORD, REPLICATION_PASSWORD, DATABASE_URL_SERVER_*.
#
# IDEMPOTENT: safe to run twice (second run is a no-op).

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

if grep -q '^WITH_DATABASE=false' project.config 2>/dev/null; then
    echo "Already stripped (WITH_DATABASE=false). Nothing to do."
    exit 0
fi

echo "==> Stripping database tier from template..."

# 1. Delete DB infrastructure directories + scripts
rm -rf etcd patroni haproxy
rm -f scripts/swarm-setup.sh
rm -f scripts/ci/deploy-db-stack.sh

# 2. Flip the flag in project.config
if grep -q '^WITH_DATABASE=' project.config; then
    sed -i.bak 's/^WITH_DATABASE=.*/WITH_DATABASE=false/' project.config && rm project.config.bak
else
    echo "WITH_DATABASE=false" >> project.config
fi

# 3. Rewrite docker-compose.yml: drop db-internal network, drop secrets,
#    drop the secrets: top-level block. The app no longer talks to Postgres.
python3 - <<'PY'
import re, pathlib
p = pathlib.Path("docker-compose.yml")
s = p.read_text()
# Remove the secrets: block on the service
s = re.sub(r"\n    secrets:\n      - database_url\n", "\n", s)
# Remove db-internal from the service's networks list
s = re.sub(r"\n      - db-internal\n", "\n", s)
# Remove the entire top-level secrets: block (including any leading comments
# that introduce it). Matches from a "secrets:" at column 0 through the next
# blank line or end of file.
s = re.sub(
    r"\n(?:#[^\n]*\n)*secrets:\n(?:[ \t]+[^\n]*\n)+",
    "\n",
    s,
)
# Remove db-internal from top-level networks
s = re.sub(r"  db-internal:\n    external: true\n    name: \$\{OVERLAY_NETWORK\}\n", "", s)
p.write_text(s)
PY

# 4. Remove local-dev DB containers (if local/ exists, leave it but warn)
if [ -d local ]; then
    echo "NOTE: local/ still contains the DB stack. Edit local/docker-compose.yml"
    echo "      manually to remove etcd/patroni/haproxy services if you want a"
    echo "      pure stateless local dev environment."
fi

echo "==> Done. CI will now skip deploy-db-stack. Required GitHub Secrets:"
echo "    - HETZNER_BARE_METAL_GITHUB_ACTIONS_SSH_PRIVATE_KEY"
echo "    - SENTRY_DSN"
