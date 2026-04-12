#!/bin/bash
# ---------------------------------------------------------------------------
# new-service.sh — one-command bootstrap for a brand-new dolr-ai service.
#
# This script automates the ~10-step manual process of creating a new service
# from this template. Instead of manually copying files, editing configs,
# generating passwords, creating a GitHub repo, setting secrets, pushing code,
# and waiting for CI — this script does ALL of it in one command.
#
# WHAT DOES IT DO? (12 steps)
#   1.  Validates prerequisites (gh auth, openssl, git, CI key, target dir)
#   2.  Copies this template to ~/Claude Projects/yral-<name>/
#   3.  Runs init-from-template.sh inside the copy (updates project.config)
#   4.  Generates strong POSTGRES_PASSWORD + REPLICATION_PASSWORD via openssl
#   5.  Composes DATABASE_URL_SERVER_1 + DATABASE_URL_SERVER_2
#   6.  git init + initial commit
#   7.  gh repo create dolr-ai/yral-<name> --public
#   8.  git push -u origin main
#   9.  gh secret set for all 5+ secrets (SSH key, passwords, DB URLs, Sentry)
#  10.  Watches the first CI run with `gh run watch`
#  11.  Verifies https://<PROJECT_DOMAIN>/health returns 200 (with retries)
#  12.  Prints a "next steps" summary
#
# USAGE:
#   bash scripts/new-service.sh --name my-service
#   bash scripts/new-service.sh --name foo --target-dir ~/somewhere/else
#   bash scripts/new-service.sh --name foo --no-push       # dry run (no push)
#   bash scripts/new-service.sh --name foo --sentry-dsn 'https://...'
#
# IDEMPOTENT: re-running after a partial failure resumes from the first
# step that hasn't completed yet (e.g., if `gh repo create` failed because
# the repo already exists, it skips that step and continues).
# ---------------------------------------------------------------------------

# "set -euo pipefail" = strict error handling:
#   -e: stop on any error
#   -u: treat unset variables as errors (catch typos in variable names)
#   -o pipefail: if any command in a pipe fails, the whole pipe fails
set -euo pipefail

# ----- Default values for all command-line options -----
NAME=""                # The service name (e.g., "my-service")
TARGET_DIR=""          # Where to create the new service (auto-set below)
NO_PUSH="false"        # If true, stop before pushing to GitHub
SENTRY_DSN=""          # Optional Sentry DSN for error tracking
PUSH_TO_REMOTE="true"  # Whether to push to GitHub (opposite of NO_PUSH)

# The default parent directory for all projects
DEFAULT_PARENT_DIR="${HOME}/Claude Projects"
# The GitHub organization name
ORG="dolr-ai"

# ----- Parse command-line arguments -----
# Loop through all arguments. "$#" is the count of remaining arguments.
while [ $# -gt 0 ]; do
    case "$1" in
        # --name my-service → sets the service name
        --name)        NAME="$2"; shift 2 ;;
        # --target-dir ~/somewhere → override the default target directory
        --target-dir)  TARGET_DIR="$2"; shift 2 ;;
        # --sentry-dsn 'https://...' → optional Sentry error tracking URL
        --sentry-dsn)  SENTRY_DSN="$2"; shift 2 ;;
        # --no-push → stop before pushing (useful for testing the script)
        --no-push)     NO_PUSH="true"; PUSH_TO_REMOTE="false"; shift ;;
        # -h or --help → print the header comment block and exit
        -h|--help)     sed -n '2,40p' "$0"; exit 0 ;;
        # Unrecognized argument → error
        *)             echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# --name is required
[ -z "${NAME}" ] && { echo "ERROR: --name is required"; exit 1; }
# If no --target-dir was given, use the default: ~/Claude Projects/yral-<name>
[ -z "${TARGET_DIR}" ] && TARGET_DIR="${DEFAULT_PARENT_DIR}/yral-${NAME}"

# ----- Color codes for prettier output -----
# "[ -t 1 ]" checks if stdout is a terminal (not a pipe or file).
# Colors only work in terminals; in pipes/files they'd show as garbage characters.
if [ -t 1 ]; then
    G='\033[0;32m'; R='\033[0;31m'; Y='\033[0;33m'; B='\033[0;34m'; N='\033[0m'
else
    # No colors when output is piped or redirected
    G=''; R=''; Y=''; B=''; N=''
fi
# Helper functions for consistent, colored log output
log()  { echo -e "${B}[new-service]${N} $*"; }   # Blue prefix for info messages
ok()   { echo -e "${G}  ✓${N} $*"; }             # Green check for success
warn() { echo -e "${Y}  ⚠${N} $*"; }             # Yellow warning
err()  { echo -e "${R}  ✗${N} $*" >&2; }         # Red X for errors (sent to stderr)
die()  { err "$*"; exit 1; }                       # Print error and exit

# =====================================================================
# STEP 1: Validate that all prerequisites are installed and configured
# =====================================================================
log "1/12 Validating prerequisites..."

# Check that required command-line tools are installed.
# "command -v <tool>" returns 0 if the tool exists, 1 if not.
# "|| die" means: if the check fails, print error and exit.
command -v git     >/dev/null || die "git not installed"
command -v gh      >/dev/null || die "gh not installed (brew install gh)"
command -v openssl >/dev/null || die "openssl not installed"
command -v docker  >/dev/null || die "docker not installed"

# Check that the GitHub CLI is authenticated (logged in).
# "gh auth status" returns 0 if logged in, non-zero if not.
if ! gh auth status >/dev/null 2>&1; then
    die "gh not authenticated. Run: gh auth login"
fi
ok "gh authenticated"

# Validate the service name format.
# Must be: lowercase, start with a letter, only letters/numbers/hyphens, end with letter/number.
# Examples: "my-service" ✓, "MyService" ✗, "-bad" ✗, "bad-" ✗
if ! echo "${NAME}" | grep -qE '^[a-z][a-z0-9-]*[a-z0-9]$'; then
    die "name must be lowercase alphanumeric + hyphens (e.g. my-service); got '${NAME}'"
fi
ok "name '${NAME}' is valid"

# Check Postgres database name length limit.
# PostgreSQL limits database names to 63 characters. Our convention adds "_db"
# suffix (3 chars). Hyphens are converted to underscores for SQL compatibility.
NAME_UNDERSCORE=$(echo "${NAME}" | tr '-' '_')
DB_NAME_LEN=$((${#NAME_UNDERSCORE} + 3))
[ ${DB_NAME_LEN} -gt 63 ] && die "name too long: '${NAME_UNDERSCORE}_db' would be ${DB_NAME_LEN} chars > 63 (Postgres limit)"
ok "db name length OK (${DB_NAME_LEN}/63)"

# Check Docker Swarm combined name length limit.
# Swarm limits service/secret names to 63 chars. The longest combined name is
# "${NAME}-db_replication_password" (NAME + "-db_replication_password" = NAME + 24).
# So NAME must be ≤ 39 characters.
SWARM_NAME_LEN=$(( ${#NAME} + 24 ))
[ ${SWARM_NAME_LEN} -gt 63 ] && die "name too long: combined Swarm secret name '${NAME}-db_replication_password' would be ${SWARM_NAME_LEN} chars > 63 (Docker Swarm limit). Use a name ≤39 characters."
ok "swarm name length OK (${SWARM_NAME_LEN}/63)"

# Check that the CI SSH private key exists on disk.
# This key is needed to set GitHub Secrets and for CI to SSH into servers.
TEMPLATE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${TEMPLATE_ROOT}/servers.config"
# Expand ~ to the actual home directory path
SSH_KEY="${SSH_KEY_PATH/#\~/$HOME}"
[ -f "${SSH_KEY}" ] || die "CI SSH key not found at ${SSH_KEY}"
ok "CI SSH key found"

# =====================================================================
# STEP 2: Copy the template to the target directory
# =====================================================================
log "2/12 Copying template to ${TARGET_DIR}"
if [ -d "${TARGET_DIR}" ]; then
    # Target already exists — assume this is a resume after partial failure
    warn "${TARGET_DIR} already exists (resume mode — will not overwrite)"
else
    # Create the parent directory if needed
    mkdir -p "$(dirname "${TARGET_DIR}")"
    # Copy the entire template repo to the target directory.
    # "cp -R" = recursive copy (all files and subdirectories).
    # The trailing "/" on the source ensures we copy CONTENTS, not the dir itself.
    cp -R "${TEMPLATE_ROOT}/" "${TARGET_DIR}"
    # Remove the template's .git history (we'll create a fresh one)
    rm -rf "${TARGET_DIR}/.git"
    # Remove local-only secrets that should never be copied between projects
    rm -rf "${TARGET_DIR}/local/secrets" "${TARGET_DIR}/secrets"
    ok "template copied"
fi

# Switch to the new project directory for all remaining steps
cd "${TARGET_DIR}"

# =====================================================================
# STEP 3: Run init-from-template.sh (updates project.config with new name)
# =====================================================================
log "3/12 Running init-from-template.sh"
# Check if already initialized (project.config already has the right name)
if grep -q "^PROJECT_NAME=${NAME}$" project.config 2>/dev/null; then
    ok "already initialized for ${NAME} (skip)"
else
    # init-from-template.sh asks for confirmation (y/N) — feed it "y" automatically.
    # "printf 'y\n'" sends "y" followed by a newline.
    # ">/dev/null" suppresses the script's output (it's verbose).
    printf 'y\n' | bash scripts/init-from-template.sh "${NAME}" >/dev/null
    ok "project.config updated"
fi

# Re-source the updated project.config so the rest of this script uses
# the NEW values (PROJECT_NAME, PROJECT_DOMAIN, POSTGRES_DB, etc.)
set -a
# shellcheck disable=SC1091
source ./project.config
set +a

# =====================================================================
# STEP 4: Generate strong random passwords for the database
# =====================================================================
log "4/12 Generating strong secrets"
# Store secrets in a local directory that's gitignored
SECRETS_DIR=".bootstrap-secrets"
mkdir -p "${SECRETS_DIR}"
# 700 = only the owner can read/write/enter (nobody else can see the passwords)
chmod 700 "${SECRETS_DIR}"

# Generate a 32-byte (64-character hex) random password for the PostgreSQL superuser.
# "openssl rand -hex 32" generates cryptographically secure random bytes.
# Only generate if not already generated (idempotent for resume mode).
if [ ! -f "${SECRETS_DIR}/postgres_password" ]; then
    openssl rand -hex 32 > "${SECRETS_DIR}/postgres_password"
fi
# Generate a separate password for database replication
if [ ! -f "${SECRETS_DIR}/replication_password" ]; then
    openssl rand -hex 32 > "${SECRETS_DIR}/replication_password"
fi
# 600 = only the owner can read/write the password files
chmod 600 "${SECRETS_DIR}"/*

# Read the generated passwords into variables
PG_PASS=$(cat "${SECRETS_DIR}/postgres_password")
REPL_PASS=$(cat "${SECRETS_DIR}/replication_password")
# Compose the full DATABASE_URL for each server.
# Format: postgresql://username:password@host:port/database_name
# Server 1 connects via haproxy-rishi-1, Server 2 via haproxy-rishi-2.
# HAProxy routes to the current Patroni leader (wherever it is).
DB_URL_1="postgresql://postgres:${PG_PASS}@haproxy-rishi-1:5432/${POSTGRES_DB}"
DB_URL_2="postgresql://postgres:${PG_PASS}@haproxy-rishi-2:5432/${POSTGRES_DB}"
ok "generated 32-byte hex passwords + composed DATABASE_URLs"

# BELT AND SUSPENDERS: make sure the secrets directory is in .gitignore.
# The template's .gitignore should already list .bootstrap-secrets/, but if
# someone accidentally overwrote .gitignore, we add it back.
if ! grep -qF "${SECRETS_DIR}/" .gitignore 2>/dev/null; then
    echo "${SECRETS_DIR}/" >> .gitignore
fi
# HARD GUARD: if any file in .bootstrap-secrets/ would be tracked by git,
# STOP immediately. This check would have caught the 2026-04-09 incident
# where a sync from the template overwrote .gitignore and the bootstrap
# secrets got committed to a public repo.
if [ -d .git ] && git status --porcelain "${SECRETS_DIR}/" 2>/dev/null | grep -qE '^\?\?|^A '; then
    : # untracked files are fine — they're being gitignored correctly
fi
# Check if any secrets are already tracked by git (VERY BAD if true)
if [ -d .git ] && git ls-files --error-unmatch "${SECRETS_DIR}" >/dev/null 2>&1; then
    die "FATAL: ${SECRETS_DIR}/ is tracked by git! .gitignore is broken. Run: git rm --cached -r ${SECRETS_DIR} && git commit -m 'fix gitignore'"
fi

# =====================================================================
# STEPS 5-6: Initialize a git repo and create the initial commit
# =====================================================================
log "5/12 Initializing git repo + initial commit"
if [ ! -d .git ]; then
    # Initialize a new git repo with "main" as the default branch
    git init -q -b main
    # Stage ALL files for the initial commit
    git add -A
    # Create the initial commit with a temporary git identity
    # (this only affects this one commit, not global git config).
    # -q = quiet (don't print the commit summary)
    git -c user.email="bootstrap@dolr-ai" -c user.name="new-service.sh" \
        commit -q -m "Initial commit from yral-rishi-hetzner-infra-template"
    ok "git repo initialized + initial commit"
else
    ok "git repo already exists (skip)"
fi

# =====================================================================
# STEP 7: Create the GitHub repository
# =====================================================================
log "6/12 Creating GitHub repo ${ORG}/${PROJECT_REPO}"
# Check if the repo already exists on GitHub
if gh repo view "${ORG}/${PROJECT_REPO}" >/dev/null 2>&1; then
    ok "repo already exists (skip)"
    # Make sure the local repo has the remote set up even if it already exists
    if ! git remote get-url origin >/dev/null 2>&1; then
        git remote add origin "git@github.com:${ORG}/${PROJECT_REPO}.git"
    fi
else
    # Create a new public repo under the dolr-ai org.
    # --public: visible to everyone (required for free GitHub Actions minutes)
    # --source=.: use the current local repo
    # --remote=origin: set "origin" as the remote name
    gh repo create "${ORG}/${PROJECT_REPO}" --public --source=. --remote=origin >/dev/null
    ok "repo created"
fi

# =====================================================================
# STEP 8: Push to GitHub
# =====================================================================
if [ "${PUSH_TO_REMOTE}" = "true" ]; then
    log "7/12 Pushing to origin/main"
    # "push -u origin main" pushes and sets up tracking (so future "git push" works)
    # "push.autoSetupRemote=true" avoids the need to specify the remote branch
    if git -c push.autoSetupRemote=true push -u origin main >/dev/null 2>&1; then
        ok "pushed"
    else
        # If push fails (e.g., already up to date), that's fine
        ok "push not needed (already up to date)"
    fi
else
    # --no-push was specified — stop here
    warn "7/12 --no-push specified; stopping before push"
    exit 0
fi

# =====================================================================
# STEP 9: Set GitHub Secrets (needed by CI for deployment)
# =====================================================================
log "8/12 Setting GitHub Secrets"

# Helper function to set a single GitHub Secret.
# Takes: key name, value
set_secret() {
    local key="$1"; local value="$2"
    # Skip if the value is empty (e.g., SENTRY_DSN when not provided)
    if [ -z "${value}" ]; then
        warn "  skipping ${key} (empty)"
        return
    fi
    # Set the secret using the -b (body) flag.
    # NOTE: gh secret set's stdin reading is unreliable across versions.
    # The -b flag with a quoted argument is the only consistently working method.
    # Do NOT use --body - (literal "-") or pipe via stdin (silently empty).
    if gh secret set "${key}" --repo "${ORG}/${PROJECT_REPO}" -b "${value}" >/dev/null 2>&1; then
        ok "  set ${key}"
    else
        err "  failed to set ${key}"
    fi
}

# Set each required secret:
# The CI SSH private key (so CI can SSH into the Hetzner servers)
set_secret HETZNER_BARE_METAL_GITHUB_ACTIONS_SSH_PRIVATE_KEY "$(cat "${SSH_KEY}")"
# The PostgreSQL superuser password
set_secret POSTGRES_PASSWORD     "${PG_PASS}"
# The database replication password
set_secret REPLICATION_PASSWORD  "${REPL_PASS}"
# The full database URL for each server (used by the app to connect)
set_secret DATABASE_URL_SERVER_1 "${DB_URL_1}"
set_secret DATABASE_URL_SERVER_2 "${DB_URL_2}"
# Sentry DSN is optional — only set if provided via --sentry-dsn
[ -n "${SENTRY_DSN}" ] && set_secret SENTRY_DSN "${SENTRY_DSN}"

# =====================================================================
# STEP 10: Watch the first CI run
# =====================================================================
# IMPORTANT: filter by --workflow=deploy.yml specifically. On a fresh repo,
# the dependabot.yml we ship triggers a Dependabot scan that often finishes
# BEFORE the deploy run. Without the filter, `gh run list --limit 1` would
# return the Dependabot run instead of the deploy run.
log "9/12 Waiting for deploy.yml run to start..."
RID=""
# Try up to 6 times (30 seconds) to find the deploy run
for i in 1 2 3 4 5 6; do
    sleep 5
    # List the most recent deploy.yml run and extract its ID
    # --json databaseId: output the run's database ID as JSON
    # -q '.[0].databaseId': extract just the ID number
    RID=$(gh run list --repo "${ORG}/${PROJECT_REPO}" --workflow=deploy.yml --limit 1 \
            --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")
    # If we found a run, stop waiting
    [ -n "${RID}" ] && break
    log "  (attempt ${i}/6, no run yet)"
done
if [ -n "${RID}" ]; then
    log "watching deploy.yml run ${RID} (this can take ~5 minutes for the first deploy)"
    # "gh run watch" shows real-time progress. --exit-status makes it return
    # non-zero if the run fails (so we can detect failures).
    gh run watch "${RID}" --repo "${ORG}/${PROJECT_REPO}" --exit-status >/dev/null 2>&1 \
        && ok "CI run completed successfully" \
        || warn "CI run did not finish cleanly. Inspect with: gh run view ${RID} --repo ${ORG}/${PROJECT_REPO} --log-failed"
else
    warn "no deploy.yml run found after 30s — push may still be propagating"
fi

# =====================================================================
# STEP 11: Verify the deployed service is live and healthy
# =====================================================================
log "10/12 Verifying https://${PROJECT_DOMAIN}/health (will retry up to 90s)"
HEALTH_OK=0
# Try up to 30 times with 3-second sleeps = 90 seconds max
for i in $(seq 1 30); do
    # curl the /health endpoint.
    # -fsS: fail silently on HTTP errors, show errors on network failures.
    # --max-time 5: give up after 5 seconds per attempt.
    if curl -fsS --max-time 5 "https://${PROJECT_DOMAIN}/health" >/dev/null 2>&1; then
        HEALTH_OK=1
        ok "service is live and healthy"
        break
    fi
    sleep 3
done
if [ "${HEALTH_OK}" = "0" ]; then
    warn "health endpoint not returning 200 yet. Check the CI run + 'curl -v https://${PROJECT_DOMAIN}/health' manually."
fi

# =====================================================================
# STEP 12: Save a local record of the bootstrap secrets + print summary
# =====================================================================
log "11/12 Recording bootstrap secrets locally"
# Create a README in the secrets directory so future-you knows what these files are
cat > "${SECRETS_DIR}/README.md" <<EOF
# Bootstrap secrets for ${PROJECT_REPO}

These are the secrets generated by scripts/new-service.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
They have already been pushed to GitHub Secrets — this is your local copy as a backup.

DO NOT commit this directory. It is gitignored.

POSTGRES_PASSWORD:    \`$(cat "${SECRETS_DIR}/postgres_password")\`
REPLICATION_PASSWORD: \`$(cat "${SECRETS_DIR}/replication_password")\`

If you need to rotate these, run \`bash scripts/rotate-secrets.sh --apply\`.
EOF

log "12/12 Done"
echo
# Print a summary of everything that was created
echo -e "${G}========================================================${N}"
echo -e "${G} ${PROJECT_REPO} bootstrapped${N}"
echo
echo " Repo:        https://github.com/${ORG}/${PROJECT_REPO}"
echo " URL:         https://${PROJECT_DOMAIN}/"
echo " Local path:  ${TARGET_DIR}"
echo " Secrets:     ${TARGET_DIR}/${SECRETS_DIR}/ (gitignored)"
echo
echo " Next steps:"
echo "   cd \"${TARGET_DIR}\""
echo "   # Edit your business logic in app/database.py + app/main.py"
echo "   # Test locally: bash local/setup.sh && curl http://localhost:8080/"
echo "   # When happy, push your changes — CI redeploys automatically."
echo
echo "   # Run integration tests on the new service:"
echo "   bash tests/integration/run_all.sh ${PROJECT_DOMAIN}"
echo -e "${G}========================================================${N}"
