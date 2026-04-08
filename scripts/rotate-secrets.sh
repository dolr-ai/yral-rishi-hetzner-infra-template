#!/bin/bash
# rotate-secrets.sh — generate fresh strong secrets and print the gh CLI
# commands to update them on the GitHub repo.
#
# Does NOT touch GitHub or the servers automatically — it prints what to run
# so you can review before applying. Designed to be safe to run anytime.
#
# Usage:
#   bash scripts/rotate-secrets.sh
#   bash scripts/rotate-secrets.sh --apply   # actually run the gh commands
#
# After applying:
#   1. Trigger a redeploy: gh workflow run deploy.yml
#   2. Verify the new app pods come up healthy
#   3. Old DB connections survive until pool recycle (~few minutes)

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

source project.config

PG_PASS=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
REPL_PASS=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
DB_URL_1="postgresql://postgres:${PG_PASS}@haproxy-rishi-1:5432/${POSTGRES_DB}"
DB_URL_2="postgresql://postgres:${PG_PASS}@haproxy-rishi-2:5432/${POSTGRES_DB}"

CMDS=(
  "gh secret set POSTGRES_PASSWORD --body '${PG_PASS}'"
  "gh secret set REPLICATION_PASSWORD --body '${REPL_PASS}'"
  "gh secret set DATABASE_URL_SERVER_1 --body '${DB_URL_1}'"
  "gh secret set DATABASE_URL_SERVER_2 --body '${DB_URL_2}'"
)

if [ "${1:-}" = "--apply" ]; then
    echo "==> Applying rotated secrets to GitHub repo..."
    for c in "${CMDS[@]}"; do
        echo "  $ $c"
        eval "$c"
    done
    echo
    echo "==> Done. Trigger a redeploy with: gh workflow run deploy.yml"
else
    echo "==> Dry run. Review and re-run with --apply to execute:"
    echo
    for c in "${CMDS[@]}"; do
        echo "  $c"
    done
    echo
    echo "Then trigger a redeploy: gh workflow run deploy.yml"
fi
