#!/bin/bash
# ---------------------------------------------------------------------------
# rotate-secrets.sh — generate new database passwords and update GitHub.
#
# WHAT IS SECRET ROTATION?
# Over time, passwords can be compromised (leaked in logs, stolen by an
# attacker, etc.). "Rotating" means generating brand-new random passwords
# and replacing the old ones everywhere they're used.
#
# WHAT THIS SCRIPT DOES:
# 1. Generates two new random 32-character passwords
# 2. Composes the new DATABASE_URL strings (containing the new password)
# 3. Prints the `gh secret set` commands to update GitHub Secrets
#
# By default, it's a DRY RUN — it only SHOWS what it would do.
# Add --apply to actually run the commands.
#
# USAGE:
#   bash scripts/rotate-secrets.sh            # preview only (safe)
#   bash scripts/rotate-secrets.sh --apply    # actually update GitHub
#
# AFTER APPLYING:
#   1. Push a commit (or run: gh workflow run deploy.yml) to redeploy
#   2. The new passwords will be used on the next deploy
#   3. Existing database connections keep working until the pool recycles
# ---------------------------------------------------------------------------

# "set -e" = stop the script if any command fails
set -e

# Find the root directory of this project (one level up from scripts/)
# "$(dirname "$0")" = the directory containing this script
# "cd ... && pwd" = go there and print the full path
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Change to the project root directory
cd "${REPO_ROOT}"

# Load project.config to get POSTGRES_DB (the database name)
# "source" reads the file and makes its variables available in this script
source project.config

# Generate a new random password for the PostgreSQL superuser (postgres)
# "openssl rand -base64 32" = generate 32 random bytes, encode as base64 text
# "tr -d '/+='" = remove characters that cause problems in URLs (/, +, =)
# "head -c 32" = take only the first 32 characters
PG_PASS=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)

# Generate a DIFFERENT random password for the replication user
# (the user that replicas use to stream data from the leader)
REPL_PASS=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)

# Compose the DATABASE_URL for each app server.
# These URLs contain the new password and tell the app WHERE the database is.
# haproxy-rishi-1 = HAProxy on server 1 (routes to the DB leader)
# haproxy-rishi-2 = HAProxy on server 2 (same leader, different route)
DB_URL_1="postgresql://postgres:${PG_PASS}@haproxy-rishi-1:5432/${POSTGRES_DB}"
DB_URL_2="postgresql://postgres:${PG_PASS}@haproxy-rishi-2:5432/${POSTGRES_DB}"

# Build the list of `gh secret set` commands.
# "gh" is the GitHub CLI tool. "gh secret set NAME --body VALUE" updates
# a GitHub Secret (encrypted storage for passwords used by CI).
CMDS=(
  "gh secret set POSTGRES_PASSWORD --body '${PG_PASS}'"
  "gh secret set REPLICATION_PASSWORD --body '${REPL_PASS}'"
  "gh secret set DATABASE_URL_SERVER_1 --body '${DB_URL_1}'"
  "gh secret set DATABASE_URL_SERVER_2 --body '${DB_URL_2}'"
)

# Check if --apply was passed as an argument
# "${1:-}" means "the first argument, or empty string if none"
if [ "${1:-}" = "--apply" ]; then
    # APPLY MODE: actually run the commands
    echo "==> Applying rotated secrets to GitHub repo..."
    # Loop through each command in the CMDS array
    for c in "${CMDS[@]}"; do
        echo "  $ $c"   # Print the command (so you can see what's running)
        eval "$c"        # Execute the command
    done
    echo
    echo "==> Done. Trigger a redeploy with: gh workflow run deploy.yml"
else
    # DRY RUN MODE: just show the commands without running them
    echo "==> Dry run. Review and re-run with --apply to execute:"
    echo
    for c in "${CMDS[@]}"; do
        echo "  $c"
    done
    echo
    echo "Then trigger a redeploy: gh workflow run deploy.yml"
fi
