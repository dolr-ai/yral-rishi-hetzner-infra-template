#!/bin/bash
# Test 1 — App-tier redundancy when one server is unreachable.
#
# Simulates "rishi-1 is down" by stopping Caddy on rishi-1. Cloudflare DNS
# round-robin retries the other origin transparently when TCP is refused.
#
# Usage: bash test_01_server_failover.sh [PROJECT_DOMAIN]

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh" "${1:-}"

URL="https://${PROJECT_DOMAIN}/"
CLEANUP_NEEDED=0

cleanup() {
    if [ "${CLEANUP_NEEDED}" = "1" ]; then
        log "cleanup: starting Caddy on rishi-1 again"
        ssh_to "${SERVER_1_IP}" 'docker start caddy >/dev/null 2>&1' || true
    fi
    [ "${FAILED}" = "1" ] && exit 1
    exit 0
}
trap cleanup EXIT INT TERM

log "Test 1: server failover for ${URL}"

# Baseline
log "baseline: 5 hits"
for i in 1 2 3 4 5; do
    if curl_ok "${URL}"; then
        :
    else
        fail "baseline request $i failed; aborting"
        exit 1
    fi
done
START=$(get_counter "${URL}")
[ -n "${START}" ] || { fail "could not parse counter from baseline response"; exit 1; }
pass "baseline OK, counter=${START}"

# Knock out rishi-1's Caddy
log "stopping caddy on rishi-1 (${SERVER_1_IP})"
ssh_to "${SERVER_1_IP}" 'docker stop caddy >/dev/null' || die "could not stop caddy on rishi-1"
CLEANUP_NEEDED=1

# Sample for 30s
log "sampling URL 10x over ~30s while rishi-1 is unreachable"
SUCCESS=0; FAIL_COUNT=0
PREV_COUNTER=${START}
for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 3
    RESP=$(curl -sk --max-time 8 "${URL}" 2>/dev/null || echo "")
    if echo "${RESP}" | grep -q '"message".*Person'; then
        N=$(echo "${RESP}" | sed -n 's/.*Person \([0-9]*\).*/\1/p')
        if [ -n "${N}" ] && [ "${N}" -gt "${PREV_COUNTER}" ]; then
            SUCCESS=$((SUCCESS+1))
            PREV_COUNTER=${N}
        else
            FAIL_COUNT=$((FAIL_COUNT+1))
            log "  [$i] counter not advancing (got ${N}, prev ${PREV_COUNTER})"
        fi
    else
        FAIL_COUNT=$((FAIL_COUNT+1))
        log "  [$i] FAIL response='${RESP:0:80}'"
    fi
done

log "results: ${SUCCESS}/10 success, ${FAIL_COUNT}/10 failed"

if [ "${SUCCESS}" -ge 9 ]; then
    pass "≥9/10 requests succeeded with rishi-1 down (Cloudflare RR failover working)"
else
    fail "only ${SUCCESS}/10 requests succeeded with rishi-1 down — Cloudflare RR failover NOT working as expected"
fi

# Cleanup happens via trap
