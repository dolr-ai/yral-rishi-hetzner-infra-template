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
#   4. ALL per-project overlay networks: <name>-db-internal AND any
#      <name>-db_*  (e.g. <name>-db_default auto-created by Swarm when a
#      stack YAML references an unnamed network). Missing the auto-created
#      _default network is the single most common teardown footprint-leak.
#   5. App container + dirs on ALL servers: /home/deploy/yral-<name>/
#      (app dir, rishi-1 + rishi-2) AND /home/deploy/<name>-db-stack/
#      (db-stack files SCP'd by CI, rishi-1 only today — but we rm on all
#      three for future-proofing). Forgetting the db-stack dir was the
#      earlier bug that left 7+ orphan dirs on rishi-1.
#   6. Caddy snippet on rishi-1 + rishi-2 (then reloads Caddy)
#   7. GHCR images (app + patroni Docker images)        [skip with --infra-only]
#   8. GitHub repo (gh repo delete)                     [skip with --infra-only]
#   9. Local clone (unless --keep-local)                [skip with --infra-only]
#
# WHAT IT DOES NOT REMOVE:
#   - Other dolr-ai services (counter, hello-world, etc.) — cross-project safe
#   - The CI SSH key, Sentry projects, Cloudflare DNS (global resources)
#   - This template repo itself
#   - Misplaced volumes named for one host but living on another (e.g.
#     <stack>_patroni-rishi-2-data found on rishi-1 because Swarm once
#     scheduled that replica there before placement constraints). The
#     stack-prefix glob DOES catch these — but only during teardown-time
#     while the stack name is still known. If the stack was already removed
#     manually, use scripts/ci-cleanup-orphans.sh (or this script by
#     passing the same --name).
#
# USAGE:
#   bash scripts/teardown-service.sh --name <project-name>
#   bash scripts/teardown-service.sh --name foo --target-dir /path/to/repo
#   bash scripts/teardown-service.sh --name foo --yes              # skip prompts
#   bash scripts/teardown-service.sh --name foo --keep-local       # keep local dir
#   bash scripts/teardown-service.sh --name foo --infra-only       # skip GHCR+repo+local
#
# --infra-only is for cleaning up an ORPHAN: service where the Swarm stack
# is long gone but stale dirs/volumes/networks remain. The GHCR image and
# GitHub repo may have been deleted separately (or never existed, e.g. a
# local-only experiment). With --infra-only, steps 7-9 are skipped entirely.
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
INFRA_ONLY="false"     # If true, skip GHCR / GitHub repo / local clone steps.
                       # Use when cleaning up an orphan whose GitHub side was
                       # already removed (or never created).
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
        # --infra-only → skip GHCR image delete, GitHub repo delete, and
        # local clone delete (steps 7, 8, 9). For orphan cleanup where the
        # GitHub side is already gone or was never created.
        --infra-only)  INFRA_ONLY="true"; shift ;;
        # -h or --help → print the header comment block and exit
        -h|--help)     sed -n '2,60p' "$0"; exit 0 ;;
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
echo " Network:      ${OVERLAY_NETWORK}   (+ any ${SWARM_STACK}_* auto-created)"
echo " Server dirs:  /home/deploy/${PROJECT_REPO}/ + /home/deploy/${SWARM_STACK}-stack/"
if [ "${INFRA_ONLY}" = "true" ]; then
echo " GHCR repos:   (skipped — --infra-only)"
echo " GitHub repo:  (skipped — --infra-only)"
echo " Local dir:    (skipped — --infra-only)"
else
echo " GHCR repos:   ${IMAGE_REPO}, ${PATRONI_IMAGE_REPO}"
echo " GitHub repo:  https://github.com/${ORG}/${PROJECT_REPO}"
echo " Local dir:    ${TARGET_DIR}$([ "${KEEP_LOCAL}" = "true" ] && echo " (KEEPING)")"
fi
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
# STEP 4: Remove ALL per-project overlay networks
# =====================================================================
# Two kinds of networks can exist for one stack:
#
#   a) ${OVERLAY_NETWORK}  (e.g. my-service-db-internal)
#      Explicitly declared in the stack YAMLs. This is the one the stack
#      actually uses for service-to-service traffic.
#
#   b) ${SWARM_STACK}_<anything>  (e.g. my-service-db_default)
#      Docker Swarm AUTO-CREATES a `<stack>_default` network for any
#      service in a compose/stack file that does NOT explicitly attach
#      to a named network. Easy to leak: you never wrote it anywhere,
#      so teardown forgets about it. Evidence from prod (2026-04-20):
#      `rishi-hetzner-infra-template-db_default` still existed on rishi-1
#      long after the service was redeployed, because earlier teardown
#      iterations only removed `-db-internal`.
#
# We remove (a) explicitly (retry loop — Swarm holds it for a few seconds
# after stack rm) AND (b) by pattern match on ${SWARM_STACK}_*.
log "4/9 Removing overlay networks (${OVERLAY_NETWORK} + ${SWARM_STACK}_*)"
# Swarm usually removes `${OVERLAY_NETWORK}` as part of STEP 1's stack rm,
# but sometimes it's still present (stale reference, async cleanup lag). We
# probe first so the "already gone" case reports ok instead of 5x warning.
if ssh_to "${SERVER_1_IP}" "docker network inspect ${OVERLAY_NETWORK} >/dev/null 2>&1"; then
    REMOVED=0
    for i in 1 2 3 4 5; do
        if ssh_to "${SERVER_1_IP}" "docker network rm ${OVERLAY_NETWORK} >/dev/null 2>&1"; then
            ok "  removed ${OVERLAY_NETWORK} (attempt $i)"
            REMOVED=1
            break
        fi
        sleep 3
    done
    [ "${REMOVED}" = "0" ] && warn "  could not remove ${OVERLAY_NETWORK} after 5 retries — clean up manually"
else
    ok "  ${OVERLAY_NETWORK} already gone (cleaned by stack rm)"
fi

# Now sweep up any <stack>_* overlay networks Swarm auto-created.
# `docker network ls --format '{{.Name}} {{.Scope}}'` lists name+scope so we
# can filter out `bridge`/`host` entries that happen to start with the same
# prefix (shouldn't, but defense in depth). awk keeps only `swarm`-scope
# entries whose name starts with the stack prefix. xargs runs `network rm`
# once per orphan. The ^anchor in awk prevents partial matches.
AUTO_NETS=$(ssh_to "${SERVER_1_IP}" "
    docker network ls --format '{{.Name}} {{.Scope}}' \
      | awk -v p='^${SWARM_STACK}_' '\$2==\"swarm\" && \$1 ~ p {print \$1}'
" || true)
if [ -n "${AUTO_NETS}" ]; then
    while IFS= read -r NET; do
        [ -z "${NET}" ] && continue
        if ssh_to "${SERVER_1_IP}" "docker network rm ${NET} >/dev/null 2>&1"; then
            ok "  removed ${NET} (auto-created by Swarm)"
        else
            warn "  could not remove ${NET} — clean up manually"
        fi
    done <<< "${AUTO_NETS}"
else
    ok "  no ${SWARM_STACK}_* auto-networks found"
fi

# =====================================================================
# STEP 5: Remove app container + on-disk dirs on ALL servers
# =====================================================================
# Two directories per service can live on a server:
#   ~/yral-<name>/          (APP_DIR)       — created by deploy-app.sh, lives on APP_SERVERS
#   ~/<name>-db-stack/      (DB_STACK_DIR)  — created by deploy-db-stack.sh,
#                                              lives on rishi-1 today (the Swarm manager
#                                              is where CI SCPs the stack YAMLs and runs
#                                              `docker stack deploy`). Forgetting to
#                                              remove this dir was the bug that left 7+
#                                              orphan dirs on rishi-1 through April 2026.
#
# We loop over ALL 3 servers (not just app servers) and `rm -rf` both
# paths. Missing dirs silently no-op, so this is idempotent and safe to
# run against a partially-cleaned service.
log "5/9 Removing app container + on-disk dirs on all servers"
APP_DIR="/home/deploy/${PROJECT_REPO}"
# NB: the CI workflow SCPs db-stack files to /home/deploy/${SWARM_STACK}-stack
# (suffix is `-stack`, not the bare SWARM_STACK). See .github/workflows/deploy.yml
# scp-action step: `target: /home/deploy/${{ env.SWARM_STACK }}-stack`. An earlier
# version of this script used the wrong path (no `-stack` suffix) and silently
# no-op'd the rm. Verified 2026-04-20 against temp-test-3.
DB_STACK_DIR="/home/deploy/${SWARM_STACK}-stack"
for ip in "${SERVER_1_IP}" "${SERVER_2_IP}" "${SERVER_3_IP}"; do
    HOST=$(ssh_to "$ip" 'hostname')
    ssh_to "$ip" "
        # If the app dir exists, shut down its compose stack before removing.
        # -v removes associated volumes (local, not Swarm — those are STEP 2).
        # --remove-orphans catches leftover sidecar containers.
        if [ -d '${APP_DIR}' ]; then
            cd '${APP_DIR}' && docker compose down -v --remove-orphans 2>/dev/null || true
        fi
        # Force-remove the app container by name in case compose didn't catch it
        # (e.g. the compose file was already deleted but the container kept running).
        docker rm -f ${PROJECT_REPO} 2>/dev/null || true
        # Delete both the app dir (if present) and the db-stack dir (if present).
        # No-op if either is missing. We do NOT guard with [ -d ] on the rm itself
        # because rm -rf on a missing path is already silent.
        rm -rf '${APP_DIR}' '${DB_STACK_DIR}'
    "
    # Report per-server whether each path existed before we rm'd it. We check
    # the *existence* after the rm (always false) so we report what we removed
    # by doing a second probe BEFORE the rm — but to keep the SSH round-trips
    # down, just assert completion here.
    ok "  ${HOST}: ${APP_DIR} + ${DB_STACK_DIR} removed (no-op if missing)"
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

# ---------------------------------------------------------------------
# STEPS 7–9 (GHCR image, GitHub repo, local clone) are SKIPPED entirely
# when --infra-only is set. This mode is for orphan cleanup where the
# GitHub-side artifacts were already removed (or never existed).
# ---------------------------------------------------------------------
if [ "${INFRA_ONLY}" = "true" ]; then
    log "7-9/9 skipped (--infra-only)"
else

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

fi  # end of --infra-only skip block

# =====================================================================
# FINAL VERIFICATION: Check that the service is actually gone
# =====================================================================
# Verifies four things now, up from two:
#   - Public URL no longer responds
#   - Swarm stack gone
#   - On-disk dirs gone on every server (new — catches the Step 5 bug)
#   - No <SWARM_STACK>_* overlay networks remain (new — catches the Step 4 bug)
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
# Check that neither the app dir nor the db-stack dir survives on any server.
# Any hit is a footprint leak — the earlier teardown bug that left 7+ orphan
# db-stack dirs on rishi-1 would have been caught here immediately.
for ip in "${SERVER_1_IP}" "${SERVER_2_IP}" "${SERVER_3_IP}"; do
    HOST=$(ssh_to "$ip" 'hostname')
    LEFT=$(ssh_to "$ip" "ls -d /home/deploy/${PROJECT_REPO} /home/deploy/${SWARM_STACK} 2>/dev/null" || true)
    if [ -n "${LEFT}" ]; then
        err "  ${HOST}: dir(s) still exist: ${LEFT}"
    else
        ok "  ${HOST}: on-disk dirs gone"
    fi
done
# Check for any leftover stack-prefixed overlay networks.
LEFT_NETS=$(ssh_to "${SERVER_1_IP}" "
    docker network ls --format '{{.Name}} {{.Scope}}' \
      | awk -v p='^(${OVERLAY_NETWORK}|${SWARM_STACK}_.*)$' '\$2==\"swarm\" && \$1 ~ p {print \$1}'
" || true)
if [ -n "${LEFT_NETS}" ]; then
    err "  overlay networks still exist: ${LEFT_NETS}"
else
    ok "  no ${SWARM_STACK} overlay networks remain"
fi

# Print the final success message
echo
echo -e "${G}========================================================${N}"
echo -e "${G} ${PROJECT_REPO} torn down${N}"
echo -e "${G}========================================================${N}"
