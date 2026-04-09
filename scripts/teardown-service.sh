#!/bin/bash
# =============================================================================
# teardown-service.sh — completely remove a dolr-ai service from infra + GitHub.
#
# Reverse of scripts/new-service.sh. Use this for throwaway test services or
# when permanently retiring a service.
#
# Usage:
#   bash scripts/teardown-service.sh --name <project-name>
#   bash scripts/teardown-service.sh --name foo --target-dir /path/to/repo
#   bash scripts/teardown-service.sh --name foo --yes              # skip prompts
#   bash scripts/teardown-service.sh --name foo --keep-local       # don't delete the local dir
#
# What it removes:
#   1. Swarm stack (etcd + Patroni + HAProxy)
#   2. Patroni data volumes on rishi-1, rishi-2, rishi-3
#   3. Per-project Swarm secrets (postgres_password, replication_password)
#   4. Per-project overlay network
#   5. App container + /home/deploy/<repo>/ on rishi-1 + rishi-2
#   6. Caddy snippet on rishi-1 + rishi-2 (then reload Caddy)
#   7. GHCR images (app + patroni)
#   8. GitHub repo (gh repo delete)
#   9. Local clone (unless --keep-local)
#
# What it does NOT remove:
#   - Counter / hello-world / any other dolr-ai service (cross-project safe)
#   - The CI SSH key, Sentry projects, Cloudflare DNS (those are global resources)
#   - This template repo itself
#
# IDEMPOTENT: each step swallows "not found" errors so re-running is safe.
# =============================================================================

set -uo pipefail

NAME=""
TARGET_DIR=""
ASSUME_YES="false"
KEEP_LOCAL="false"
ORG="dolr-ai"
DEFAULT_PARENT_DIR="${HOME}/Claude Projects"

while [ $# -gt 0 ]; do
    case "$1" in
        --name)        NAME="$2"; shift 2 ;;
        --target-dir)  TARGET_DIR="$2"; shift 2 ;;
        --yes)         ASSUME_YES="true"; shift ;;
        --keep-local)  KEEP_LOCAL="true"; shift ;;
        -h|--help)     sed -n '2,40p' "$0"; exit 0 ;;
        *)             echo "Unknown arg: $1"; exit 1 ;;
    esac
done

[ -z "${NAME}" ] && { echo "ERROR: --name is required"; exit 1; }
[ -z "${TARGET_DIR}" ] && TARGET_DIR="${DEFAULT_PARENT_DIR}/yral-${NAME}"

# Color
if [ -t 1 ]; then
    G='\033[0;32m'; R='\033[0;31m'; Y='\033[0;33m'; B='\033[0;34m'; N='\033[0m'
else
    G=''; R=''; Y=''; B=''; N=''
fi
log()  { echo -e "${B}[teardown]${N} $*"; }
ok()   { echo -e "${G}  ✓${N} $*"; }
warn() { echo -e "${Y}  ⚠${N} $*"; }
err()  { echo -e "${R}  ✗${N} $*" >&2; }
die()  { err "$*"; exit 1; }

# ----- Load config from the local clone (preferred) or fall back to template defaults -----
if [ -f "${TARGET_DIR}/project.config" ]; then
    set -a
    # shellcheck disable=SC1091
    source "${TARGET_DIR}/project.config"
    set +a
    log "loaded project.config from ${TARGET_DIR}"
else
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

# ----- Load servers.config from the template (always available) -----
TEMPLATE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a
# shellcheck disable=SC1091
source "${TEMPLATE_ROOT}/servers.config"
set +a
SSH_KEY="${SSH_KEY_PATH/#\~/$HOME}"

ssh_to() {
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o LogLevel=ERROR \
        "${DEPLOY_USER}@$1" "$2"
}

# ----- Confirmation -----
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

if [ "${ASSUME_YES}" != "true" ]; then
    read -p "Type the project name '${NAME}' to confirm: " CONFIRM
    [ "${CONFIRM}" = "${NAME}" ] || die "confirmation did not match; aborting"
fi

# ----- 1. Remove Swarm stack -----
log "1/9 Removing Swarm stack ${SWARM_STACK}"
ssh_to "${SERVER_1_IP}" "docker stack rm ${SWARM_STACK} 2>/dev/null" || true
ok "stack rm issued"

# Wait for tasks to drain (up to 60s)
log "    waiting for tasks to drain..."
for i in $(seq 1 20); do
    REMAINING=$(ssh_to "${SERVER_1_IP}" "docker stack ps ${SWARM_STACK} 2>/dev/null | tail -n +2 | wc -l | tr -d ' '" || echo "0")
    [ "${REMAINING}" = "0" ] && { ok "    drained"; break; }
    sleep 3
done

# ----- 2. Remove Patroni + etcd volumes on each server -----
# Both stacks create per-node data volumes. Earlier versions of this script
# only removed the patroni volumes and left etcd volumes orphaned, which
# accumulated over multiple teardown/redeploy cycles. Now we sweep ALL
# volumes prefixed with the swarm stack name on every node.
log "2/9 Removing Patroni + etcd data volumes (every ${SWARM_STACK}_* on every node)"
for ip in "${SERVER_1_IP}" "${SERVER_2_IP}" "${SERVER_3_IP}"; do
    HOST=$(ssh_to "$ip" 'hostname')
    LEFTOVER=$(ssh_to "$ip" "docker volume ls -q | grep '^${SWARM_STACK}_' || true")
    if [ -z "${LEFTOVER}" ]; then
        ok "  ${HOST}: clean"
        continue
    fi
    while IFS= read -r VOL; do
        [ -z "${VOL}" ] && continue
        if ssh_to "$ip" "docker volume rm ${VOL} >/dev/null 2>&1"; then
            ok "  ${HOST}: removed ${VOL}"
        else
            warn "  ${HOST}: could not remove ${VOL} (in use? Swarm may still be draining)"
        fi
    done <<< "${LEFTOVER}"
done

# ----- 3. Remove namespaced Swarm secrets -----
log "3/9 Removing namespaced Swarm secrets"
for SECRET in "${SWARM_STACK}_postgres_password" "${SWARM_STACK}_replication_password"; do
    ssh_to "${SERVER_1_IP}" "docker secret rm ${SECRET} >/dev/null 2>&1" \
        && ok "  removed ${SECRET}" \
        || warn "  ${SECRET} not found (already gone)"
done

# ----- 4. Remove per-project overlay network -----
# Swarm sometimes holds the network for several seconds after stack rm
# completes. Retry up to 5 times before giving up.
log "4/9 Removing overlay network ${OVERLAY_NETWORK}"
REMOVED=0
for i in 1 2 3 4 5; do
    if ssh_to "${SERVER_1_IP}" "docker network rm ${OVERLAY_NETWORK} >/dev/null 2>&1"; then
        ok "  removed (attempt $i)"
        REMOVED=1
        break
    fi
    sleep 3
done
[ "${REMOVED}" = "0" ] && warn "  could not remove ${OVERLAY_NETWORK} after 5 retries — clean up manually"

# ----- 5. Remove app container + dir on rishi-1 + rishi-2 -----
log "5/9 Removing app container + dir on rishi-1, rishi-2"
for ip in "${SERVER_1_IP}" "${SERVER_2_IP}"; do
    HOST=$(ssh_to "$ip" 'hostname')
    ssh_to "$ip" "
        cd /home/deploy/${PROJECT_REPO} 2>/dev/null && docker compose down -v --remove-orphans 2>/dev/null || true
        docker rm -f ${PROJECT_REPO} 2>/dev/null || true
        rm -rf /home/deploy/${PROJECT_REPO}
    "
    ok "  ${HOST}: app removed"
done

# ----- 6. Remove Caddy snippet + reload -----
log "6/9 Removing Caddy snippet + reloading"
for ip in "${SERVER_1_IP}" "${SERVER_2_IP}"; do
    HOST=$(ssh_to "$ip" 'hostname')
    ssh_to "$ip" "
        rm -f /home/deploy/caddy/conf.d/${PROJECT_REPO}.caddy
        docker exec caddy caddy reload --config /etc/caddy/Caddyfile --force 2>/dev/null || true
    "
    ok "  ${HOST}: snippet removed + Caddy reloaded"
done

# ----- 7. Delete GHCR images -----
log "7/9 Deleting GHCR images"
for IMG_NAME in "${PROJECT_REPO}" "${PROJECT_REPO}-patroni"; do
    if gh api "/orgs/${ORG}/packages/container/${IMG_NAME}" >/dev/null 2>&1; then
        gh api -X DELETE "/orgs/${ORG}/packages/container/${IMG_NAME}" >/dev/null 2>&1 \
            && ok "  deleted ghcr.io/${ORG}/${IMG_NAME}" \
            || warn "  could not delete ${IMG_NAME} (need admin:packages scope?)"
    else
        warn "  ghcr.io/${ORG}/${IMG_NAME} not found"
    fi
done

# ----- 8. Delete the GitHub repo -----
log "8/9 Deleting GitHub repo ${ORG}/${PROJECT_REPO}"
if gh repo view "${ORG}/${PROJECT_REPO}" >/dev/null 2>&1; then
    gh repo delete "${ORG}/${PROJECT_REPO}" --yes >/dev/null 2>&1 \
        && ok "  deleted" \
        || warn "  could not delete (need delete_repo scope? run 'gh auth refresh -h github.com -s delete_repo')"
else
    warn "  not found (already gone)"
fi

# ----- 9. Remove local clone -----
log "9/9 Local clone"
if [ "${KEEP_LOCAL}" = "true" ]; then
    warn "  --keep-local set; leaving ${TARGET_DIR}"
elif [ -d "${TARGET_DIR}" ]; then
    rm -rf "${TARGET_DIR}"
    ok "  removed ${TARGET_DIR}"
else
    warn "  ${TARGET_DIR} not found"
fi

# ----- Final verification -----
echo
log "Verification:"
if curl -fsS --max-time 5 "https://${PROJECT_DOMAIN}/health" >/dev/null 2>&1; then
    err "  ${PROJECT_DOMAIN}/health STILL responds — teardown incomplete!"
else
    ok "  ${PROJECT_DOMAIN} no longer responds"
fi
if ssh_to "${SERVER_1_IP}" "docker stack ls --format '{{.Name}}' | grep -q '^${SWARM_STACK}$'" 2>/dev/null; then
    err "  Swarm stack ${SWARM_STACK} still exists"
else
    ok "  Swarm stack ${SWARM_STACK} gone"
fi

echo
echo -e "${G}========================================================${N}"
echo -e "${G} ${PROJECT_REPO} torn down${N}"
echo -e "${G}========================================================${N}"
