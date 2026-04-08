#!/bin/bash
# Test 2 — One server unreachable AND Patroni leader killed simultaneously.
#
# - Stops Caddy on rishi-1 (Cloudflare can't reach that origin)
# - Kills the current Patroni leader container (could be on any server)
# - Verifies the surviving app server keeps serving via the newly-elected leader
#
# Usage: bash test_02_server_and_leader_failover.sh [PROJECT_DOMAIN]

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh" "${1:-}"

URL="https://${PROJECT_DOMAIN}/"
RESTORE_CADDY=0
RESTORE_PATRONI_HOST=""
RESTORE_PATRONI_NAME=""

cleanup() {
    if [ "${RESTORE_CADDY}" = "1" ]; then
        log "cleanup: restarting caddy on rishi-1"
        ssh_to "${SERVER_1_IP}" 'docker start caddy >/dev/null 2>&1' || true
    fi
    if [ -n "${RESTORE_PATRONI_HOST}" ]; then
        log "cleanup: forcing swarm to recreate ${RESTORE_PATRONI_NAME}"
        ssh_to "${SERVER_1_IP}" "docker service update --force ${SWARM_STACK}_${RESTORE_PATRONI_NAME} >/dev/null 2>&1" || true
    fi
    [ "${FAILED}" = "1" ] && exit 1
    exit 0
}
trap cleanup EXIT INT TERM

log "Test 2: server + leader failover for ${URL}"

# Baseline
for i in 1 2 3; do
    curl_ok "${URL}" || { fail "baseline req $i failed"; exit 1; }
done
START=$(get_counter "${URL}")
pass "baseline OK, counter=${START}"

# Identify leader
LEADER_INFO=$(get_patroni_leader) || { fail "could not get patroni leader"; exit 1; }
LEADER_HOST=$(echo "${LEADER_INFO}" | awk '{print $1}')
LEADER_NAME=$(echo "${LEADER_INFO}" | awk '{print $2}')
LEADER_IP=$(server_ip_for "${LEADER_HOST}") || { fail "unknown leader host ${LEADER_HOST}"; exit 1; }
log "current Patroni leader: ${LEADER_NAME} on ${LEADER_HOST} (${LEADER_IP})"

# Stop Caddy on rishi-1 ("server down")
log "stopping caddy on rishi-1"
ssh_to "${SERVER_1_IP}" 'docker stop caddy >/dev/null' || die "could not stop caddy"
RESTORE_CADDY=1

# Kill the patroni leader (could be on any host, including rishi-1)
log "killing leader container ${LEADER_NAME} on ${LEADER_HOST}"
ssh_to "${LEADER_IP}" "docker kill \$(docker ps -qf name=${LEADER_NAME} | head -1) >/dev/null" || \
    log "  (kill returned nonzero — leader may already be down)"
RESTORE_PATRONI_HOST="${LEADER_HOST}"
RESTORE_PATRONI_NAME="${LEADER_NAME}"

# Sample every 3s for 60s; tolerate up to 6 failures during the failover window
log "sampling URL every 3s for 60s; allow ≤6 failures during the election window"
SUCCESS=0; FAIL_COUNT=0; LAST_5_SUCCESS=0
declare -a recent
for i in $(seq 1 20); do
    sleep 3
    CODE=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "${URL}" 2>/dev/null || echo "000")
    if [ "${CODE}" = "200" ]; then
        SUCCESS=$((SUCCESS+1))
        recent+=(1)
        log "  [+$((i*3))s] OK"
    else
        FAIL_COUNT=$((FAIL_COUNT+1))
        recent+=(0)
        log "  [+$((i*3))s] FAIL"
    fi
done

# Last 5 must all be successes (proves stable recovery)
LAST_5_SUCCESS=0
for v in "${recent[@]: -5}"; do
    [ "$v" = "1" ] && LAST_5_SUCCESS=$((LAST_5_SUCCESS+1))
done

log "results: ${SUCCESS}/20 success, ${FAIL_COUNT}/20 failed, last5=${LAST_5_SUCCESS}/5"

if [ "${LAST_5_SUCCESS}" = "5" ] && [ "${FAIL_COUNT}" -le 6 ]; then
    pass "service recovered: ${SUCCESS}/20 successes, last 5/5 successes"
else
    fail "did not recover within 60s: ${SUCCESS}/20 successes, last5=${LAST_5_SUCCESS}/5"
fi

# Verify a new leader was elected (and it's not the one we killed, OR it's been
# rebootstrapped on the same name — both acceptable)
sleep 5
NEW_LEADER_INFO=$(get_patroni_leader) || { fail "no leader after failover"; exit 1; }
NEW_LEADER_NAME=$(echo "${NEW_LEADER_INFO}" | awk '{print $2}')
log "new leader: ${NEW_LEADER_NAME}"
pass "patroni cluster has a leader after failover"
