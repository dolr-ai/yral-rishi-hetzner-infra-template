#!/bin/bash
# ---------------------------------------------------------------------------
# strip-database.sh — remove all database components from a forked service.
#
# WHEN TO USE:
# If your new service does NOT need a database (e.g., a stateless ML model
# that just takes input and returns predictions), run this script ONCE
# after forking from the template. It removes everything related to
# PostgreSQL, Patroni, etcd, and HAProxy.
#
# WHAT IT REMOVES:
#   - etcd/ directory (leader election — not needed without a database)
#   - patroni/ directory (PostgreSQL HA — not needed)
#   - haproxy/ directory (DB load balancer — not needed)
#   - scripts/swarm-setup.sh (Swarm cluster setup — not needed)
#   - scripts/ci/deploy-db-stack.sh (DB deployment — not needed)
#   - Database references from docker-compose.yml (secrets, networks)
#   - Sets WITH_DATABASE=false in project.config (CI skips DB deployment)
#
# AFTER RUNNING:
# Your service only needs 2 GitHub Secrets (instead of 7):
#   - HETZNER_BARE_METAL_GITHUB_ACTIONS_SSH_PRIVATE_KEY
#   - SENTRY_DSN (optional)
#
# IDEMPOTENT: safe to run twice — the second run detects WITH_DATABASE=false
# and exits immediately without changing anything.
#
# USAGE:
#   bash scripts/strip-database.sh
# ---------------------------------------------------------------------------

# Stop on any error
set -e

# Find the project root directory (one level up from scripts/)
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

# Check if already stripped — if WITH_DATABASE is already false, nothing to do
# "grep -q" searches silently (no output, just exit code)
if grep -q '^WITH_DATABASE=false' project.config 2>/dev/null; then
    echo "Already stripped (WITH_DATABASE=false). Nothing to do."
    exit 0
fi

echo "==> Stripping database tier from template..."

# ----- STEP 1: Delete database-related directories and scripts -----
# "rm -rf" = remove recursively, force (no confirmation, no error if missing)
rm -rf etcd patroni haproxy
# "rm -f" = remove file, force (no error if file doesn't exist)
rm -f scripts/swarm-setup.sh
rm -f scripts/ci/deploy-db-stack.sh

# ----- STEP 2: Set WITH_DATABASE=false in project.config -----
# "grep -q" checks if the line exists
if grep -q '^WITH_DATABASE=' project.config; then
    # "sed" (stream editor) replaces text in a file
    # 's/old/new/' = substitute old with new
    # '-i.bak' = edit in place, save backup as .bak
    # Then we delete the backup file (we don't need it)
    sed -i.bak 's/^WITH_DATABASE=.*/WITH_DATABASE=false/' project.config && rm project.config.bak
else
    # If WITH_DATABASE doesn't exist in the file, add it at the end
    echo "WITH_DATABASE=false" >> project.config
fi

# ----- STEP 3: Clean up docker-compose.yml -----
# This uses Python (a small inline script) to remove database references
# from docker-compose.yml using regular expressions (text patterns).
#
# "python3 - <<'PY'" means "run Python and feed it the text until 'PY'"
# This is called a "heredoc" — a way to embed a multi-line string in bash.
python3 - <<'PY'
import re, pathlib

# Read the entire docker-compose.yml file
p = pathlib.Path("docker-compose.yml")
s = p.read_text()

# Remove "secrets: - database_url" from the app service
# (the app no longer needs a database URL)
s = re.sub(r"\n    secrets:\n      - database_url\n", "\n", s)

# Remove "- db-internal" from the app's networks list
# (the app no longer needs the database overlay network)
s = re.sub(r"\n      - db-internal\n", "\n", s)

# Remove the entire top-level "secrets:" block (including comments above it)
# This removes the file-based secret definition for database_url
s = re.sub(
    r"\n(?:#[^\n]*\n)*secrets:\n(?:[ \t]+[^\n]*\n)+",
    "\n",
    s,
)

# Remove the db-internal network from the top-level "networks:" block
s = re.sub(r"  db-internal:\n    external: true\n    name: \$\{OVERLAY_NETWORK\}\n", "", s)

# Write the modified file back
p.write_text(s)
PY

# ----- STEP 4: Note about local dev -----
# The local/ directory has its own docker-compose with etcd/patroni containers.
# We don't auto-modify it (too complex), just warn the user.
if [ -d local ]; then
    echo "NOTE: local/ still contains the DB stack. Edit local/docker-compose.yml"
    echo "      manually to remove etcd/patroni/haproxy services if you want a"
    echo "      pure stateless local dev environment."
fi

echo "==> Done. CI will now skip deploy-db-stack. Required GitHub Secrets:"
echo "    - HETZNER_BARE_METAL_GITHUB_ACTIONS_SSH_PRIVATE_KEY"
echo "    - SENTRY_DSN"
