#!/bin/bash
# =============================================================================
# Initialize a new project from this template.
#
# Usage:
#   bash scripts/init-from-template.sh <new-project-name>
#
# Example:
#   bash scripts/init-from-template.sh nsfw-detection
#
# What this does (and the only thing it does):
#   - Edits ONE file: project.config
#   - Replaces every occurrence of `rishi-hetzner-infra-template` and
#     `rishi_hetzner_infra_template` with the new name
#
# Every other file in this repo references project.config via ${VAR}
# interpolation, so changing project.config is sufficient to retarget
# the entire stack at the new project. NO sed across the rest of the repo.
#
# After running this script:
#   1. Inspect: `cat project.config`  (verify all values look right)
#   2. Edit your business logic in app/main.py and patroni/init.sql
#   3. Test locally: `bash local/setup.sh`
#   4. When green, create the GitHub repo and push (see TEMPLATE.md)
# =============================================================================

set -e

if [ -z "$1" ]; then
    echo "Usage: bash scripts/init-from-template.sh <new-project-name>"
    echo "Example: bash scripts/init-from-template.sh nsfw-detection"
    exit 1
fi

NEW_NAME="$1"

# Validate the name (lowercase, alphanumeric + hyphens, no leading/trailing hyphen)
if ! echo "$NEW_NAME" | grep -qE '^[a-z][a-z0-9-]*[a-z0-9]$'; then
    echo "ERROR: Name must be lowercase alphanumeric with hyphens (e.g. nsfw-detection)"
    exit 1
fi

# Underscore version for the Postgres database name
NEW_NAME_UNDERSCORE=$(echo "$NEW_NAME" | tr '-' '_')

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${REPO_ROOT}/project.config"

if [ ! -f "${CONFIG}" ]; then
    echo "ERROR: ${CONFIG} not found. Are you running this from a fresh copy of the template?"
    exit 1
fi

echo "==> Renaming project to: ${NEW_NAME}"
echo "    project.config will be updated as follows:"
echo "      PROJECT_NAME=${NEW_NAME}"
echo "      PROJECT_DOMAIN=${NEW_NAME}.rishi.yral.com"
echo "      PROJECT_REPO=yral-${NEW_NAME}"
echo "      POSTGRES_DB=${NEW_NAME_UNDERSCORE}_db"
echo "      PATRONI_SCOPE=${NEW_NAME}-cluster"
echo "      ETCD_TOKEN=${NEW_NAME}-etcd-cluster"
echo "      SWARM_STACK=${NEW_NAME}-db"
echo "      OVERLAY_NETWORK=${NEW_NAME}-db-internal"
echo "      IMAGE_REPO=ghcr.io/dolr-ai/yral-${NEW_NAME}"
echo "      PATRONI_IMAGE_REPO=ghcr.io/dolr-ai/yral-${NEW_NAME}-patroni"
echo ""
read -p "Continue? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

# Replace in project.config only. Do underscore version FIRST so it doesn't
# get clobbered by the hyphenated rule.
sed -i.bak \
    -e "s|rishi_hetzner_infra_template|${NEW_NAME_UNDERSCORE}|g" \
    -e "s|rishi-hetzner-infra-template|${NEW_NAME}|g" \
    "${CONFIG}"
rm -f "${CONFIG}.bak"

echo ""
echo "✅ project.config updated. New contents:"
echo "------------------------------------------------------------"
cat "${CONFIG}"
echo "------------------------------------------------------------"
echo ""
echo "NEXT STEPS:"
echo "  1. Edit app/main.py and app/database.py with your service's business logic"
echo "  2. Edit patroni/init.sql with your DB schema (or delete if no DB needed)"
echo "  3. Update requirements.txt with your Python dependencies"
echo "  4. Update README.md / CLAUDE.md with what your service does"
echo "  5. Test locally: bash local/setup.sh"
echo "     Verify: curl http://localhost:8080/"
echo "  6. When green, create the GitHub repo:"
echo "       gh repo create dolr-ai/yral-${NEW_NAME} --public"
echo "  7. Set 9 GitHub secrets (see TEMPLATE.md)"
echo "  8. git init && git add -A && git commit -m 'Initial commit' && git push"
echo ""
echo "Note: this script does NOT touch any file other than project.config."
echo "Every other file uses \${VAR} interpolation from project.config."
