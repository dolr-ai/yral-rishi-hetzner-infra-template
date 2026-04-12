#!/bin/bash
# ---------------------------------------------------------------------------
# teardown-service.sh — completely remove a dolr-ai service from infrastructure
# and GitHub. The reverse of scripts/new-service.sh.
#
# Use this for throwaway test services or when permanently retiring a service.
#
# WHAT DOES IT REMOVE? (9 steps)
#   1. Swarm stack (etcd + Patroni + HAProxy containers)
#   2. Patroni + etcd data volumes on all 3 servers (THE DATABASE DATA!)
#   3. Per-project Swarm secrets (postgres_password, replication_password)
#   4. Per-project overlay network
#   5. App container + /home/deploy/<repo>/ on rishi-1 + rishi-2
#   6. Caddy snippet on rishi-1 + rishi-2 (then reloads Caddy)
#   7. GHCR images (app + patroni Docker images)
#   8. GitHub repo (gh repo delete)
#   9. Local clone (unless --keep-local)
#
# WHAT IT DOES NOT REMOVE:
#   - Other dolr-ai services (counter, hello-world, etc.) — cross-project safe
#   - The CI SSH key, Sentry projects, Cloudflare DNS (global resources)
#   - This template repo itself
#
# USAGE:
#   bash scripts/teardown-service.sh --name <project-name>
#   bash scripts/teardown-service.sh --name foo --target-dir /path/to/repo
#   bash scripts/teardown-service.sh --name foo --yes              # skip prompts
#   bash scripts/teardown-service.sh --name foo --keep-local       # keep local dir
#
# IDEMPOTENT: each step swallows "not found" errors, so re-running is safe.
#
# WARNING: This is DESTRUCTIVE and IRREVERSIBLE. All database data for
# this service will be permanently deleted.
# ---------------------------------------------------------------------------

# "set -uo pipefail" = strict error handling, but WITHOUT -e.
# WHY no -e? Many teardown commands are expected to fail (resource already deleted).
# We handle errors explicitly with "|| true" and "|| warn" instead.
#   -u: treat unset variables as errors (catch typos)
#   -o pipefail: if any command in a pipe fails, the whole pipe fails
set -uo pipefail

# ----- Default values for command-line options -----
NAME=""                # The service name to tear down
TARGET_DIR=""          # Where the local clone lives
ASSUME_YES="false"     # If true, skip the confirmation prompt
KEEP_LOCAL="false"     # If true, don't delete the local clone
ORG="dolr-ai"         # The GitHub organization
DEFAULT_PARENT_DIR="${HOME}/Claude Projects"

# ----- Parse command-line arguments -----
while [ $# -gt 0 ]; do
    case "$1" in
        # --name my-service → the service to tear down
        --name)        NAME="$2"; shift 2 ;;
        # --target-dir ~/path → override the default local clone path
        --target-dir)  TARGET_DIR="$2"; shift 2 ;;
        # --yes → skip the confirmation prompt (for automation/scripts)
        --yes)         ASSUME_YES="true"; shift ;;
        # --keep-local → don't delete the local clone (keep it for reference)
        --keep-local)  KEEP_LOCAL="true"; shift ;;
        # -h or --help → print the header comment block and exit
        -h|--help)     sed -n '2,40p' "$0"; exit 0 ;;
        # Unrecognized argument → error
        *)             echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# --name is required
[ -z "${NAME}" ] && { echo "ERROR: --name is required"; exit 1; }
# Default target directory is ~/Claude Projects/yral-<name>
[ -z "${TARGET_DIR}" ] && TARGET_DIR="${DEFAULT_PARENT_DIR}/yral-${NAME}"

# ----- Color codes for prettier output -----
# Colors only work in terminals (not pipes or files)
if [ -t 1 ]; then
    G='\033[0;32m'; R='\033[0;31m'; Y='\033[0;33m'; B='\033[0;34m'; N='\033[0m'
else
    G=''; R=''; Y=''; B=''; N=''
fi
# Helper functions for consistent, colored log output
log()  { echo -e "${B}[teardown]${N} $*"; }   # Blue prefix for info
ok()   { echo -e "${G}  ✓${N} $*"; }          # Green check for success
warn() { echo -e "${Y}  ⚠${N} $*"; }          # Yellow for warnings/skips
err()  { echo -e "${R}  ✗${N} $*" >&2; }      # Red X for errors
die()  { err "$*"; exit 1; }                    # Print error and exit

# ----- Load project configuration -----
# Try to load from the local clone (has the exact values), or fall back to
# reconstructing them from the --name argument (using naming conventions).
if [ -f "${TARGET_DIR}/project.config" ]; then
    # Load from the actual project.config (most reliable)
    set -a
    # shellcheck disable=SC1091
    source "${TARGET_DIR}/project.config"
    set +a
    log "loaded project.config from ${TARGET_DIR}"
else
    # No local clone — reconstruct identifiers from naming conventions.
    # This works because all names are derived deterministically from the service name.
    warn "no local clone at ${TARGET_DIR}; reconstructing identifiers from --name"
    NAME_UNDERSCORE=$(echo "${NAME}" | tr '-' '_')
    PROJECT_NAME="${NAME}"
    PROJECT_DOMAIN="${NAME}.rishi.yral.com"
    PROJECT_REPO="yral-${NAME}"
    POSTGRES_DB="${NAME_UNDERSCORE}_db"
    PATRONI_SCOPE="${NAME}-cluster"
    ETCD_TOKEN="${NAME}-etcd-cluster"
    SWARM_STACK="${NAME}-db"
    OVERLAY_NETWORK="${NAME}-db-internal"
    IMAGE_REPO="ghcr.io/${ORG}/yral-${NAME}"
    PATRONI_IMAGE_REPO="ghcr.io/${ORG}/yral-${NAME}-patroni"
fi

# ----- Load servers.config (server IPs and SSH settings) -----
# Always load from the TEMPLATE repo (which is always available, even if
# the target service's local clone doesn't exist)
TEMPLATE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a
# shellcheck disable=SC1091
source "${TEMPLATE_ROOT}/servers.config"
set +a
# Expand ~ to the actual home directory in the SSH key path
SSH_KEY="${SSH_KEY_PATH/#\~/$HOME}"

# Helper function: SSH into a server and run a command.
# Handles SSH options for non-interactive use (no host key prompts, timeouts).
ssh_to() {
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o LogLevel=ERROR \
        "${DEPLOY_USER}@$1" "$2"
}

# ----- CONFIRMATION PROMPT -----
# This is destructive! Show exactly what will be deleted and ask for confirmation.
echo
echo -e "${R}========================================================${N}"
echo -e "${R} TEARING DOWN: ${PROJECT_REPO}${N}"
echo
echo " URL:          https://${PROJECT_DOMAIN}/"
echo " Swarm stack:  ${SWARM_STACK}"
echo " Network:      ${OVERLAY_NETWORK}"
echo " GHCR repos:   ${IMAGE_REPO}, ${PATRONI_IMAGE_REPO}"
echo " GitHub repo:  https://github.com/${ORG}/${PROJECT_REPO}"
echo " Local dir:    ${TARGET_DIR}$([ "${KEEP_LOCAL}" = "true" ] && echo " (KEEPING)")"
echo
echo -e "${R} This is destructive and irreversible.${N}"
echo -e "${R}========================================================${N}"

# Unless --yes was passed, require the user to type the project name to confirm
if [ "${ASSUME_YES}" != "true" ]; then
    read -p "Type the project name '${NAME}' to confirm: " CONFIRM
    # If the typed name doesn't match, abort
    [ "${CONFIRM}" = "${NAME}" ] || die "confirmation did not match; aborting"
fi

# =====================================================================
# STEP 1: Remove the Docker Swarm stack (etcd + Patroni + HAProxy)
# =====================================================================
log "1/9 Removing Swarm stack ${SWARM_STACK}"
# "docker stack rm" removes all services in the stack.
# Run on the Swarm manager (rishi-1). "|| true" = don't fail if already removed.
ssh_to "${SERVER_1_IP}" "docker stack rm ${SWARM_STACK} 2>/dev/null" || true
ok "stack rm issued"

# Wait for all stack tasks to drain (containers to stop and be removed).
# Swarm doesn't remove containers instantly — it takes a few seconds.
log "    waiting for tasks to drain..."
for i in $(seq 1 20); do
    # Count how many tasks are still running in the stack.
    # "docker stack ps" lists tasks. "tail -n +2" skips the header line.
    # "wc -l" counts remaining lines. "tr -d ' '" removes whitespace.
    REMAINING=$(ssh_to "${SERVER_1_IP}" "docker stack ps ${SWARM_STACK} 2>/dev/null | tail -n +2 | wc -l | tr -d ' '" || echo "0")
    # If all tasks are gone, we're done waiting
    [ "${REMAINING}" = "0" ] && { ok "    drained"; break; }
    # Wait 3 seconds before checking again
    sleep 3
done

# =====================================================================
# STEP 2: Remove database data volumes on ALL 3 servers
# =====================================================================
# Both the Patroni stack and etcd stack create per-node data volumes.
# We remove ALL volumes prefixed with the swarm stack name.
log "2/9 Removing Patroni + etcd data volumes (every ${SWARM_STACK}_* on every node)"
for ip in "${SERVER_1_IP}" "${SERVER_2_IP}" "${SERVER_3_IP}"; do
    # Get the server's hostname for logging
    HOST=$(ssh_to "$ip" 'hostname')
    # List all Docker volumes whose name starts with the stack name.
    # "docker volume ls -q" lists volume names (quiet mode).
    # "grep '^${SWARM_STACK}_'" filters to only this project's volumes.
    LEFTOVER=$(ssh_to "$ip" "docker volume ls -q | grep '^${SWARM_STACK}_' || true")
    # If no volumes found, this server is clean
    if [ -z "${LEFTOVER}" ]; then
        ok "  ${HOST}: clean"
        continue
    fi
    # Loop through each volume and remove it
    while IFS= read -r VOL; do
        # Skip empty lines
        [ -z "${VOL}" ] && continue
        # "docker volume rm" deletes the volume. May fail if a container is still
        # using it (Swarm might still be draining from Step 1).
        if ssh_to "$ip" "docker volume rm ${VOL} >/dev/null 2>&1"; then
            ok "  ${HOST}: removed ${VOL}"
        else
            warn "  ${HOST}: could not remove ${VOL} (in use? Swarm may still be draining)"
        fi
    done <<< "${LEFTOVER}"
done

# =====================================================================
# STEP 3: Remove namespaced Docker Swarm secrets
# =====================================================================
log "3/9 Removing namespaced Swarm secrets"
# Swarm secrets are cluster-wide, namespaced with the stack name to avoid conflicts.
for SECRET in "${SWARM_STACK}_postgres_password" "${SWARM_STACK}_replication_password"; do
    # "docker secret rm" deletes the secret. Run on the Swarm manager.
    ssh_to "${SERVER_1_IP}" "docker secret rm ${SECRET} >/dev/null 2>&1" \
        && ok "  removed ${SECRET}" \
        || warn "  ${SECRET} not found (already gone)"
done

# =====================================================================
# STEP 4: Remove the per-project overlay network
# =====================================================================
log "4/9 Removing overlay network ${OVERLAY_NETWORK}"
# Swarm sometimes holds the network for several seconds after stack rm,
# because background cleanup is asynchronous. We retry up to 5 times.
REMOVED=0
for i in 1 2 3 4 5; do
    # "docker network rm" deletes the network
    if ssh_to "${SERVER_1_IP}" "docker network rm ${OVERLAY_NETWORK} >/dev/null 2>&1"; then
        ok "  removed (attempt $i)"
        REMOVED=1
        break
    fi
    # Wait 3 seconds before retrying
    sleep 3
done
# If we couldn't remove it after 5 tries, warn (don't fail — other cleanup continues)
[ "${REMOVED}" = "0" ] && warn "  could not remove ${OVERLAY_NETWORK} after 5 retries — clean up manually"

# =====================================================================
# STEP 5: Remove the app container + directory on rishi-1 and rishi-2
# =====================================================================
log "5/9 Removing app container + dir on rishi-1, rishi-2"
# The app runs on rishi-1 and rishi-2 (not rishi-3, which is DB-only)
for ip in "${SERVER_1_IP}" "${SERVER_2_IP}"; do
    HOST=$(ssh_to "$ip" 'hostname')
    # Run multiple cleanup commands on the server:
    ssh_to "$ip" "
        # Change to the app directory and shut down the docker-compose stack.
        # -v: remove associated volumes. --remove-orphans: clean up leftover containers.
        cd /home/deploy/${PROJECT_REPO} 2>/dev/null && docker compose down -v --remove-orphans 2>/dev/null || true
        # Force-remove the app container by name (in case compose didn't catch it)
        docker rm -f ${PROJECT_REPO} 2>/dev/null || true
        # Delete the entire app directory from the server
        rm -rf /home/deploy/${PROJECT_REPO}
    "
    ok "  ${HOST}: app removed"
done

# =====================================================================
# STEP 6: Remove the Caddy reverse proxy snippet and reload Caddy
# =====================================================================
log "6/9 Removing Caddy snippet + reloading"
# Each project has a Caddy snippet file that tells Caddy how to route
# traffic for that project's domain. Removing it and reloading Caddy
# makes Caddy stop serving that domain.
for ip in "${SERVER_1_IP}" "${SERVER_2_IP}"; do
    HOST=$(ssh_to "$ip" 'hostname')
    ssh_to "$ip" "
        # Delete the project's Caddy snippet file
        rm -f /home/deploy/caddy/conf.d/${PROJECT_REPO}.caddy
        # Tell Caddy to reload its config (picks up the removal).
        # --force: reload even if Caddy thinks nothing changed.
        docker exec caddy caddy reload --config /etc/caddy/Caddyfile --force 2>/dev/null || true
    "
    ok "  ${HOST}: snippet removed + Caddy reloaded"
done

# =====================================================================
# STEP 7: Delete Docker images from GHCR (GitHub Container Registry)
# =====================================================================
log "7/9 Deleting GHCR images"
# Each service has 2 images: the app image and the Patroni image.
for IMG_NAME in "${PROJECT_REPO}" "${PROJECT_REPO}-patroni"; do
    # Check if the image package exists in GHCR using the GitHub API
    if gh api "/orgs/${ORG}/packages/container/${IMG_NAME}" >/dev/null 2>&1; then
        # Delete the image package. "-X DELETE" sends an HTTP DELETE request.
        # This requires admin:packages scope on the GitHub token.
        gh api -X DELETE "/orgs/${ORG}/packages/container/${IMG_NAME}" >/dev/null 2>&1 \
            && ok "  deleted ghcr.io/${ORG}/${IMG_NAME}" \
            || warn "  could not delete ${IMG_NAME} (need admin:packages scope?)"
    else
        warn "  ghcr.io/${ORG}/${IMG_NAME} not found"
    fi
done

# =====================================================================
# STEP 8: Delete the GitHub repository
# =====================================================================
log "8/9 Deleting GitHub repo ${ORG}/${PROJECT_REPO}"
# Check if the repo exists on GitHub
if gh repo view "${ORG}/${PROJECT_REPO}" >/dev/null 2>&1; then
    # "gh repo delete --yes" deletes without an interactive prompt.
    # This requires delete_repo scope on the GitHub token.
    gh repo delete "${ORG}/${PROJECT_REPO}" --yes >/dev/null 2>&1 \
        && ok "  deleted" \
        || warn "  could not delete (need delete_repo scope? run 'gh auth refresh -h github.com -s delete_repo')"
else
    warn "  not found (already gone)"
fi

# =====================================================================
# STEP 9: Remove the local clone directory
# =====================================================================
log "9/9 Local clone"
if [ "${KEEP_LOCAL}" = "true" ]; then
    # User asked to keep the local directory
    warn "  --keep-local set; leaving ${TARGET_DIR}"
elif [ -d "${TARGET_DIR}" ]; then
    # Delete the entire local directory
    rm -rf "${TARGET_DIR}"
    ok "  removed ${TARGET_DIR}"
else
    warn "  ${TARGET_DIR} not found"
fi

# =====================================================================
# FINAL VERIFICATION: Check that the service is actually gone
# =====================================================================
echo
log "Verification:"
# Check if the public URL still responds (it shouldn't)
if curl -fsS --max-time 5 "https://${PROJECT_DOMAIN}/health" >/dev/null 2>&1; then
    err "  ${PROJECT_DOMAIN}/health STILL responds — teardown incomplete!"
else
    ok "  ${PROJECT_DOMAIN} no longer responds"
fi
# Check if the Swarm stack still exists (it shouldn't)
if ssh_to "${SERVER_1_IP}" "docker stack ls --format '{{.Name}}' | grep -q '^${SWARM_STACK}$'" 2>/dev/null; then
    err "  Swarm stack ${SWARM_STACK} still exists"
else
    ok "  Swarm stack ${SWARM_STACK} gone"
fi

# Print the final success message
echo
echo -e "${G}========================================================${N}"
echo -e "${G} ${PROJECT_REPO} torn down${N}"
echo -e "${G}========================================================${N}"
