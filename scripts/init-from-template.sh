#!/bin/bash
# ---------------------------------------------------------------------------
# init-from-template.sh — rename the template to your new project name.
#
# WHAT THIS SCRIPT DOES:
# Edits exactly ONE file: project.config. It replaces every occurrence of
# "rishi-hetzner-infra-template" with your new project name. Since every
# other file in the repo reads from project.config via ${VAR} interpolation,
# changing project.config is all you need to retarget the entire stack.
#
# USAGE:
#   bash scripts/init-from-template.sh my-service
#
# EXAMPLE:
#   bash scripts/init-from-template.sh nsfw-detection
#
# WHAT IT CHANGES IN project.config:
#   PROJECT_NAME → nsfw-detection
#   PROJECT_DOMAIN → nsfw-detection.rishi.yral.com
#   PROJECT_REPO → yral-nsfw-detection
#   POSTGRES_DB → nsfw_detection_db  (underscores, not hyphens)
#   PATRONI_SCOPE → nsfw-detection-cluster
#   ...and all other identifiers
#
# NOTE: you usually DON'T call this directly. The bootstrap script
# (scripts/new-service.sh) calls it automatically. This is the low-level
# renaming tool; new-service.sh is the high-level workflow.
#
# AFTER RUNNING:
#   1. Check: cat project.config (verify the values look right)
#   2. Edit app/main.py + app/database.py (your business logic)
#   3. Test locally: bash local/setup.sh
#   4. Push: git push (CI deploys automatically)
# ---------------------------------------------------------------------------

# Stop on any error
set -e

# Check if a name was provided as an argument
# "$1" is the first command-line argument (e.g., "my-service")
# "-z" means "is empty?" — if no argument was given, show usage and exit
if [ -z "$1" ]; then
    echo "Usage: bash scripts/init-from-template.sh <new-project-name>"
    echo "Example: bash scripts/init-from-template.sh my-service"
    exit 1
fi

# Store the new project name
NEW_NAME="$1"

# ----- VALIDATE THE NAME -----
# The name must follow these rules:
#   - Only lowercase letters, numbers, and hyphens
#   - Must start with a letter
#   - Must end with a letter or number (not a hyphen)
# "grep -qE" matches against a regular expression pattern:
#   ^[a-z]     = starts with a lowercase letter
#   [a-z0-9-]* = followed by any number of lowercase letters, digits, or hyphens
#   [a-z0-9]$  = ends with a letter or digit
if ! echo "$NEW_NAME" | grep -qE '^[a-z][a-z0-9-]*[a-z0-9]$'; then
    echo "ERROR: Name must be lowercase alphanumeric with hyphens (e.g. my-service)"
    exit 1
fi

# ----- CHECK NAME LENGTH -----
# Docker Swarm has a hard 63-character limit on names. The longest name
# the template generates is: "${NAME}-db_replication_password" (NAME + 24 chars).
# So NAME must be ≤ 39 characters to stay within the limit.
# "${#NEW_NAME}" is bash syntax for "length of the string NEW_NAME"
NAME_LEN=${#NEW_NAME}
if [ ${NAME_LEN} -gt 39 ]; then
    echo "ERROR: Name '${NEW_NAME}' is ${NAME_LEN} chars; max is 39."
    echo "       Reason: Docker Swarm secret '${NEW_NAME}-db_replication_password'"
    echo "       would be $((NAME_LEN + 24)) chars, exceeding the 63-char limit."
    exit 1
fi

# Create an underscore version of the name for PostgreSQL.
# PostgreSQL doesn't allow hyphens in database names, so we convert them.
# "tr '-' '_'" replaces every hyphen with an underscore.
# Example: "my-service" → "my_service"
NEW_NAME_UNDERSCORE=$(echo "$NEW_NAME" | tr '-' '_')

# Find the project root directory and the config file path
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${REPO_ROOT}/project.config"

# Make sure project.config exists (it should, if this is a fresh template copy)
if [ ! -f "${CONFIG}" ]; then
    echo "ERROR: ${CONFIG} not found. Are you running this from a fresh copy of the template?"
    exit 1
fi

# Show the user what will change and ask for confirmation
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

# "read -p" prompts the user and waits for input
# "-n 1" = read only 1 character
# "-r" = don't interpret backslashes
read -p "Continue? (y/N) " -n 1 -r
echo ""

# Check if the user typed "y" or "Y"
# "[[ ... =~ ^[Yy]$ ]]" is regex matching: starts with Y or y, nothing else
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

# ----- DO THE REPLACEMENT -----
# "sed" (stream editor) does find-and-replace in text files.
# "-i.bak" = edit the file in place, save a backup as .bak
# "-e 's|old|new|g'" = substitute "old" with "new" globally (all occurrences)
#
# We do the UNDERSCORE version FIRST because "rishi_hetzner_infra_template"
# is a substring of "rishi-hetzner-infra-template" in some patterns. If we
# did the hyphen version first, it would change the underscores in POSTGRES_DB
# incorrectly.
sed -i.bak \
    -e "s|rishi_hetzner_infra_template|${NEW_NAME_UNDERSCORE}|g" \
    -e "s|rishi-hetzner-infra-template|${NEW_NAME}|g" \
    "${CONFIG}"

# Delete the backup file (we don't need it; git has the history)
rm -f "${CONFIG}.bak"

# Show the result
echo ""
echo "project.config updated. New contents:"
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
