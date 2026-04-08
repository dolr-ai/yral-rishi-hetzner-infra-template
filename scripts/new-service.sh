#!/bin/bash
# =============================================================================
# new-service.sh — one-command bootstrap for a brand-new dolr-ai service
# from this template.
#
# Replaces the ~10-step manual ritual (cp, init, gh repo create, generate
# passwords, set 5 secrets one-at-a-time, push, watch CI). Now: one command.
#
# Usage:
#   bash scripts/new-service.sh --name nsfw-detection
#   bash scripts/new-service.sh --name foo --target-dir ~/somewhere/else
#   bash scripts/new-service.sh --name foo --no-push       # dry run
#   bash scripts/new-service.sh --name foo --sentry-dsn 'https://...'
#
# What it does:
#   1.  Validates prerequisites (gh auth, openssl, git, CI key, target dir)
#   2.  Copies this template to ~/Claude Projects/yral-<name>/ (or --target-dir)
#   3.  Runs scripts/init-from-template.sh inside the copy
#   4.  Generates strong POSTGRES_PASSWORD + REPLICATION_PASSWORD via openssl
#   5.  Composes DATABASE_URL_SERVER_1 + DATABASE_URL_SERVER_2
#   6.  git init + initial commit
#   7.  gh repo create dolr-ai/yral-<name> --public
#   8.  git push -u origin main
#   9.  gh secret set for all 5 secrets (Sentry DSN optional)
#  10.  Watches the first CI run with `gh run watch`
#  11.  Verifies https://<PROJECT_DOMAIN>/health returns 200 (with retries)
#  12.  Prints a "next steps" summary
#
# IDEMPOTENT: re-running after a partial failure resumes from the first
# step that hasn't completed yet (e.g., if `gh repo create` failed because
# the repo already exists, it skips that step and continues).
# =============================================================================

set -euo pipefail

# ----- defaults -----
NAME=""
TARGET_DIR=""
NO_PUSH="false"
SENTRY_DSN=""
PUSH_TO_REMOTE="true"

DEFAULT_PARENT_DIR="${HOME}/Claude Projects"
ORG="dolr-ai"

# ----- arg parsing -----
while [ $# -gt 0 ]; do
    case "$1" in
        --name)        NAME="$2"; shift 2 ;;
        --target-dir)  TARGET_DIR="$2"; shift 2 ;;
        --sentry-dsn)  SENTRY_DSN="$2"; shift 2 ;;
        --no-push)     NO_PUSH="true"; PUSH_TO_REMOTE="false"; shift ;;
        -h|--help)     sed -n '2,40p' "$0"; exit 0 ;;
        *)             echo "Unknown arg: $1"; exit 1 ;;
    esac
done

[ -z "${NAME}" ] && { echo "ERROR: --name is required"; exit 1; }
[ -z "${TARGET_DIR}" ] && TARGET_DIR="${DEFAULT_PARENT_DIR}/yral-${NAME}"

# ----- color -----
if [ -t 1 ]; then
    G='\033[0;32m'; R='\033[0;31m'; Y='\033[0;33m'; B='\033[0;34m'; N='\033[0m'
else
    G=''; R=''; Y=''; B=''; N=''
fi
log()  { echo -e "${B}[new-service]${N} $*"; }
ok()   { echo -e "${G}  ✓${N} $*"; }
warn() { echo -e "${Y}  ⚠${N} $*"; }
err()  { echo -e "${R}  ✗${N} $*" >&2; }
die()  { err "$*"; exit 1; }

# ----- 1. validate prerequisites -----
log "1/12 Validating prerequisites..."

command -v git     >/dev/null || die "git not installed"
command -v gh      >/dev/null || die "gh not installed (brew install gh)"
command -v openssl >/dev/null || die "openssl not installed"
command -v docker  >/dev/null || die "docker not installed"

if ! gh auth status >/dev/null 2>&1; then
    die "gh not authenticated. Run: gh auth login"
fi
ok "gh authenticated"

# Validate name format (matches init-from-template.sh)
if ! echo "${NAME}" | grep -qE '^[a-z][a-z0-9-]*[a-z0-9]$'; then
    die "name must be lowercase alphanumeric + hyphens (e.g. nsfw-detection); got '${NAME}'"
fi
ok "name '${NAME}' is valid"

# Postgres DB name limit is 63 chars (and we add '_db' suffix)
NAME_UNDERSCORE=$(echo "${NAME}" | tr '-' '_')
DB_NAME_LEN=$((${#NAME_UNDERSCORE} + 3))
[ ${DB_NAME_LEN} -gt 63 ] && die "name too long: '${NAME_UNDERSCORE}_db' would be ${DB_NAME_LEN} chars > 63 (Postgres limit)"
ok "db name length OK (${DB_NAME_LEN}/63)"

# CI SSH key
TEMPLATE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${TEMPLATE_ROOT}/servers.config"
SSH_KEY="${SSH_KEY_PATH/#\~/$HOME}"
[ -f "${SSH_KEY}" ] || die "CI SSH key not found at ${SSH_KEY}"
ok "CI SSH key found"

# ----- 2. copy template (skip if target already exists) -----
log "2/12 Copying template to ${TARGET_DIR}"
if [ -d "${TARGET_DIR}" ]; then
    warn "${TARGET_DIR} already exists (resume mode — will not overwrite)"
else
    mkdir -p "$(dirname "${TARGET_DIR}")"
    # rsync preserves the trailing-slash semantics so we don't end up with nested dirs
    cp -R "${TEMPLATE_ROOT}/" "${TARGET_DIR}"
    rm -rf "${TARGET_DIR}/.git"
    # Wipe local-only volumes/secrets that should never be copied
    rm -rf "${TARGET_DIR}/local/secrets" "${TARGET_DIR}/secrets"
    ok "template copied"
fi

cd "${TARGET_DIR}"

# ----- 3. run init-from-template.sh -----
log "3/12 Running init-from-template.sh"
if grep -q "^PROJECT_NAME=${NAME}$" project.config 2>/dev/null; then
    ok "already initialized for ${NAME} (skip)"
else
    # init-from-template prompts y/N — feed it y
    printf 'y\n' | bash scripts/init-from-template.sh "${NAME}" >/dev/null
    ok "project.config updated"
fi

# Re-source the new project.config so the rest of the script uses the right values
set -a
# shellcheck disable=SC1091
source ./project.config
set +a

# ----- 4. generate secrets -----
log "4/12 Generating strong secrets"
SECRETS_DIR=".bootstrap-secrets"
mkdir -p "${SECRETS_DIR}"
chmod 700 "${SECRETS_DIR}"

if [ ! -f "${SECRETS_DIR}/postgres_password" ]; then
    openssl rand -hex 32 > "${SECRETS_DIR}/postgres_password"
fi
if [ ! -f "${SECRETS_DIR}/replication_password" ]; then
    openssl rand -hex 32 > "${SECRETS_DIR}/replication_password"
fi
chmod 600 "${SECRETS_DIR}"/*
PG_PASS=$(cat "${SECRETS_DIR}/postgres_password")
REPL_PASS=$(cat "${SECRETS_DIR}/replication_password")
DB_URL_1="postgresql://postgres:${PG_PASS}@haproxy-rishi-1:5432/${POSTGRES_DB}"
DB_URL_2="postgresql://postgres:${PG_PASS}@haproxy-rishi-2:5432/${POSTGRES_DB}"
ok "generated 32-byte hex passwords + composed DATABASE_URLs"

# Make sure the bootstrap secrets directory is gitignored
if ! grep -q "^${SECRETS_DIR}/" .gitignore 2>/dev/null; then
    echo "${SECRETS_DIR}/" >> .gitignore
fi

# ----- 5-6. git init + initial commit -----
log "5/12 Initializing git repo + initial commit"
if [ ! -d .git ]; then
    git init -q -b main
    git add -A
    git -c user.email="bootstrap@dolr-ai" -c user.name="new-service.sh" \
        commit -q -m "Initial commit from yral-rishi-hetzner-infra-template"
    ok "git repo initialized + initial commit"
else
    ok "git repo already exists (skip)"
fi

# ----- 7. gh repo create -----
log "6/12 Creating GitHub repo ${ORG}/${PROJECT_REPO}"
if gh repo view "${ORG}/${PROJECT_REPO}" >/dev/null 2>&1; then
    ok "repo already exists (skip)"
    if ! git remote get-url origin >/dev/null 2>&1; then
        git remote add origin "git@github.com:${ORG}/${PROJECT_REPO}.git"
    fi
else
    gh repo create "${ORG}/${PROJECT_REPO}" --public --source=. --remote=origin >/dev/null
    ok "repo created"
fi

# ----- 8. push -----
if [ "${PUSH_TO_REMOTE}" = "true" ]; then
    log "7/12 Pushing to origin/main"
    if git -c push.autoSetupRemote=true push -u origin main >/dev/null 2>&1; then
        ok "pushed"
    else
        # Already pushed
        ok "push not needed (already up to date)"
    fi
else
    warn "7/12 --no-push specified; stopping before push"
    exit 0
fi

# ----- 9. set secrets -----
log "8/12 Setting GitHub Secrets"

set_secret() {
    local key="$1"; local value="$2"
    if [ -z "${value}" ]; then
        warn "  skipping ${key} (empty)"
        return
    fi
    printf '%s' "${value}" | gh secret set "${key}" --repo "${ORG}/${PROJECT_REPO}" --body - >/dev/null 2>&1 \
        && ok "  set ${key}" \
        || err "  failed to set ${key}"
}

set_secret HETZNER_BARE_METAL_GITHUB_ACTIONS_SSH_PRIVATE_KEY "$(cat "${SSH_KEY}")"
set_secret POSTGRES_PASSWORD     "${PG_PASS}"
set_secret REPLICATION_PASSWORD  "${REPL_PASS}"
set_secret DATABASE_URL_SERVER_1 "${DB_URL_1}"
set_secret DATABASE_URL_SERVER_2 "${DB_URL_2}"
[ -n "${SENTRY_DSN}" ] && set_secret SENTRY_DSN "${SENTRY_DSN}"

# ----- 10. watch CI -----
log "9/12 Waiting for CI run to start..."
sleep 5
RID=$(gh run list --repo "${ORG}/${PROJECT_REPO}" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")
if [ -n "${RID}" ]; then
    log "watching run ${RID} (this can take ~5 minutes for the first deploy)"
    gh run watch "${RID}" --repo "${ORG}/${PROJECT_REPO}" --exit-status >/dev/null 2>&1 \
        && ok "CI run completed successfully" \
        || warn "CI run did not finish cleanly. Inspect with: gh run view ${RID} --repo ${ORG}/${PROJECT_REPO} --log-failed"
else
    warn "no CI run found yet — push may still be propagating"
fi

# ----- 11. verify /health -----
log "10/12 Verifying https://${PROJECT_DOMAIN}/health (will retry up to 90s)"
HEALTH_OK=0
for i in $(seq 1 30); do
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

# ----- 12. summary -----
log "11/12 Recording bootstrap secrets locally"
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
