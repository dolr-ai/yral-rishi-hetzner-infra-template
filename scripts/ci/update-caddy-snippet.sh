#!/bin/bash
# ---------------------------------------------------------------------------
# update-caddy-snippet.sh — write/refresh the per-project Caddy snippet on
# a host that runs Caddy but NOT the app container itself (rishi-3 today).
#
# WHY THIS EXISTS:
# scripts/ci/deploy-app.sh handles the case where Caddy and the app live
# on the same host (rishi-1, rishi-2). It pulls the new image, starts the
# container, runs the health check, then writes the Caddy snippet.
#
# rishi-3 is different: it is in the Cloudflare wildcard `*.rishi`
# DNS round-robin (so Cloudflare sometimes routes user traffic there)
# but it does NOT run app containers — its role is the Patroni/etcd DB
# trio + the self-hosted Sentry stack. Until 2026-05-03 it had no Caddy
# at all, which silently dropped 1-in-3 Cloudflare probes (returned 521).
#
# This script is the rishi-3 equivalent of the Caddy-snippet step in
# deploy-app.sh: it just writes the snippet (with all upstreams pointing
# at remote APP_SERVERS via the swarm overlay), records the overlay in
# .overlays-list for persistence, and reloads Caddy.
#
# WHAT THIS SCRIPT DOES (5 steps):
#   1. Source project.config + servers.config to know PROJECT_REPO,
#      PROJECT_DOMAIN, OVERLAY_NETWORK, APP_SERVERS.
#   2. Determine SERVER_NAME from local IPs (matches deploy-app.sh logic).
#      Refuse to run if SERVER_NAME IS in APP_SERVERS — that case is
#      already handled by the full deploy-app.sh and running this would
#      double-write the snippet.
#   3. Compute upstream list — first APP_SERVER as `LOCAL_UPSTREAM` (so
#      `lb_policy first` has a deterministic primary), the rest as
#      `PEER_UPSTREAMS`. Both upstreams are remote here — there is no
#      true "local" container — but the snippet template still expects
#      both placeholders, so this keeps the rendering uniform.
#   4. Render snippet → /home/deploy/caddy/conf.d/${PROJECT_REPO}.caddy
#      via the same atomic-swap + validate pattern as deploy-app.sh.
#   5. Append OVERLAY_NETWORK to /home/deploy/caddy/.overlays-list +
#      run render-caddy-compose.sh so Caddy is persistently attached.
#
# REQUIRED ENVIRONMENT (passed by CI workflow):
#   APP_DIR — directory on the server where project files were SCP'd.
#             Same convention as deploy-app.sh.
# ---------------------------------------------------------------------------

set -e

if [ ! -d "${APP_DIR}" ]; then
    echo "FATAL: APP_DIR does not exist: ${APP_DIR}"
    exit 1
fi
cd "${APP_DIR}"

# Load project + server config into the env (same pattern as deploy-app.sh).
set -a
source ./project.config
source ./servers.config
set +a

# ----------------------------------------------------------------------
# Determine which server we are running on (matches deploy-app.sh logic).
# ----------------------------------------------------------------------
OUR_IPS=$(ip -4 addr show 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}')
SERVER_NAME=""
for var in $(compgen -v SERVER_ | grep '_IP$'); do
    ip_val="${!var}"
    if echo "${OUR_IPS}" | grep -qxF "${ip_val}"; then
        n=$(echo "${var}" | sed -E 's/^SERVER_([0-9]+)_IP$/\1/')
        SERVER_NAME="rishi-${n}"
        break
    fi
done
if [ -z "${SERVER_NAME}" ]; then
    echo "FATAL: could not determine SERVER_NAME from local IPs:"
    echo "${OUR_IPS}"
    exit 1
fi

# Refuse to run on APP_SERVERS — those are handled by deploy-app.sh which
# already writes the snippet. Running both would race on the snippet file.
if [[ ",${APP_SERVERS}," == *",${SERVER_NAME},"* ]]; then
    echo "FATAL: ${SERVER_NAME} is in APP_SERVERS — use deploy-app.sh instead"
    exit 1
fi

echo "==> Updating Caddy snippet for ${PROJECT_REPO} on ${SERVER_NAME} (Caddy-only host)"

# ----------------------------------------------------------------------
# Compute upstream list — all entries are remote (this host has no app).
# Use the first APP_SERVER as LOCAL_UPSTREAM (the snippet template's
# primary slot), remaining APP_SERVERS as PEER_UPSTREAMS. Caddy's
# `lb_policy first` will prefer the first listed upstream and fall
# through to peers when it fails health-check — exactly the behavior we
# want from a Caddy-only host with no local container to prefer.
# ----------------------------------------------------------------------
IFS=',' read -ra APP_SERVER_LIST <<< "${APP_SERVERS}"
if [ ${#APP_SERVER_LIST[@]} -eq 0 ]; then
    echo "FATAL: APP_SERVERS is empty in servers.config"
    exit 1
fi
LOCAL_UPSTREAM="${PROJECT_REPO}-${APP_SERVER_LIST[0]}:8000"
PEER_UPSTREAMS=""
for peer in "${APP_SERVER_LIST[@]:1}"; do
    PEER_UPSTREAMS="${PEER_UPSTREAMS:+${PEER_UPSTREAMS} }${PROJECT_REPO}-${peer}:8000"
done
echo "    primary upstream: ${LOCAL_UPSTREAM}"
echo "    peer    upstreams: ${PEER_UPSTREAMS:-(none)}"

# ----------------------------------------------------------------------
# Render snippet (atomic swap pattern, same as deploy-app.sh).
# ----------------------------------------------------------------------
mkdir -p /home/deploy/caddy/conf.d
SNIPPET_DEST="/home/deploy/caddy/conf.d/${PROJECT_REPO}.caddy"
SNIPPET_TMP="${SNIPPET_DEST}.tmp"
sed -e "s|\${PROJECT_DOMAIN}|${PROJECT_DOMAIN}|g" \
    -e "s|\${PROJECT_REPO}|${PROJECT_REPO}|g" \
    -e "s|\${LOCAL_UPSTREAM}|${LOCAL_UPSTREAM}|g" \
    -e "s|\${PEER_UPSTREAMS}|${PEER_UPSTREAMS}|g" \
    caddy/snippet.caddy.template > "${SNIPPET_TMP}"

# Validate before swap, swap atomically, validate after, reload Caddy.
docker exec caddy caddy validate --config /etc/caddy/Caddyfile || {
    echo "FATAL: existing Caddy config invalid before swap, aborting"
    rm -f "${SNIPPET_TMP}"
    exit 1
}
mv "${SNIPPET_TMP}" "${SNIPPET_DEST}"
docker exec caddy caddy validate --config /etc/caddy/Caddyfile || {
    echo "FATAL: new snippet broke Caddy config, removing"
    rm -f "${SNIPPET_DEST}"
    exit 1
}
docker exec caddy caddy reload --config /etc/caddy/Caddyfile --force

# ----------------------------------------------------------------------
# Persist the overlay attachment via render-caddy-compose.sh (same
# pattern as deploy-app.sh). On a Caddy-only host the local `web` bridge
# is not needed (no local app to proxy to), so we set the helper's
# CADDY_INCLUDE_WEB_BRIDGE flag to "false".
# ----------------------------------------------------------------------
install -m 0755 "${APP_DIR}/caddy/render-caddy-compose.sh" /home/deploy/caddy/render-caddy-compose.sh

OVERLAYS_FILE="/home/deploy/caddy/.overlays-list"
if [ ! -f "${OVERLAYS_FILE}" ]; then
    docker inspect caddy --format '{{range $n, $_ := .NetworkSettings.Networks}}{{$n}}{{"\n"}}{{end}}' 2>/dev/null \
        | grep -v '^web$' | grep -v '^$' \
        > "${OVERLAYS_FILE}"
    echo "    initialized ${OVERLAYS_FILE} from current Caddy attachments:"
    sed 's/^/      /' "${OVERLAYS_FILE}"
fi
if ! grep -qxF "${OVERLAY_NETWORK}" "${OVERLAYS_FILE}"; then
    echo "${OVERLAY_NETWORK}" >> "${OVERLAYS_FILE}"
    echo "    added ${OVERLAY_NETWORK} to ${OVERLAYS_FILE}"
fi
CADDY_INCLUDE_WEB_BRIDGE=false /home/deploy/caddy/render-caddy-compose.sh

echo "==> ${PROJECT_REPO} Caddy snippet on ${SERVER_NAME} is up to date"
