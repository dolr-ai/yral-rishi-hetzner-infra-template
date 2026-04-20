#!/bin/bash
# Test 5 — App-CONTAINER failover (the production-incident failure mode).
#
# This test exists because the 2026-04-19 yral-chat-ai incident wasn't caught
# by test_01: test_01 kills Caddy (TCP refuses; Cloudflare cleanly routes to
# the other origin), but the incident was Caddy ALIVE and the app container
# DEAD — Caddy returned 502, which Cloudflare passes straight through to
# users. For 27 hours, ~50% of requests got 502s because rishi-1's Caddy had
# no peer to fall back to.
#
# The fix: Caddy's `reverse_proxy` now lists local + peer upstream(s) with
# an active `health_uri /health` probe. If the local container dies, Caddy
# quarantines it within ~4s and transparently forwards to the peer over the
# Swarm overlay network. This test asserts that user-visible success stays
# at 100% during that failover.
#
# What this test does, per victim host (rishi-1 then rishi-2):
#   1. Baseline: 5 hits via the public URL — must all return 200.
#   2. `docker stop` the APP container on the victim host.
#   3. Brief warmup (6s) for Caddy's active health probe to detect the
#      dead local upstream. Passive health + lb_try_duration usually catch
#      it faster, but we give the explicit window so the strict assertion
#      below is about steady-state failover, not the moment of transition.
#   4. 60 requests at 500ms intervals — ALL must succeed (60/60).
#   5. `docker start` the APP container.
#   6. Wait up to 45s for the container to report healthy again.
#   7. 20 post-recovery requests — all must succeed and the counter must
#      advance monotonically (proves Caddy is back to hitting a live app,
#      not serving a cached response).
#
# Usage: bash test_05_app_container_failover.sh [PROJECT_DOMAIN]

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh" "${1:-}"

URL="https://${PROJECT_DOMAIN}/"
HEALTH_URL="https://${PROJECT_DOMAIN}/health"
# Which hosts currently run the app. Read from servers.config (already
# sourced by lib.sh). We'll run the kill/restart cycle against each one.
IFS=',' read -ra VICTIMS <<< "${APP_SERVERS}"

# Track which victim is mid-test so the cleanup trap knows what to restart.
# Empty string means no container is currently stopped by this test.
CURRENT_VICTIM=""

cleanup() {
    if [ -n "${CURRENT_VICTIM}" ]; then
        local victim_ip
        victim_ip=$(server_ip_for "${CURRENT_VICTIM}")
        log "cleanup: restarting ${PROJECT_REPO} on ${CURRENT_VICTIM} (${victim_ip})"
        ssh_to "${victim_ip}" "docker start ${PROJECT_REPO} >/dev/null 2>&1" || true
    fi
    [ "${FAILED}" = "1" ] && exit 1
    exit 0
}
trap cleanup EXIT INT TERM

log "Test 5: app-CONTAINER failover for ${URL}"
log "victims: ${VICTIMS[*]}"

# Baseline — service must be 100% healthy before we start breaking things.
# We also decide here whether the service's root response exposes a useful
# "counter" that advances per-request: counter-style services (like the
# template) embed a request-scoped integer; stateless APIs (like chat-ai)
# return a static JSON envelope with a version number that never changes.
# If the counter doesn't advance during baseline, we skip the counter-
# advancing check during post-recovery so the test isn't mis-failed on a
# non-counter service. 200-status assertions still apply in both modes.
log "baseline: 5 hits"
for i in 1 2 3 4 5; do
    if ! curl_ok "${URL}"; then
        fail "baseline request $i failed; aborting (fix the service before running this test)"
        exit 1
    fi
done
START=$(get_counter "${URL}")
[ -n "${START}" ] || { fail "could not parse counter from baseline response"; exit 1; }
# Probe once more — if the counter ticked up, treat this as a counter-style
# service. Otherwise, record that counter checks should be skipped.
sleep 1
BASELINE_SECOND=$(get_counter "${URL}")
COUNTER_AVAILABLE=0
if [ -n "${BASELINE_SECOND}" ] && [ "${BASELINE_SECOND}" -gt "${START}" ]; then
    COUNTER_AVAILABLE=1
    START=${BASELINE_SECOND}
    pass "baseline OK, counter advancing (now ${START})"
else
    pass "baseline OK, static response (counter check will be skipped)"
fi

for VICTIM in "${VICTIMS[@]}"; do
    VICTIM_IP=$(server_ip_for "${VICTIM}")
    [ -n "${VICTIM_IP}" ] || { fail "unknown victim host: ${VICTIM}"; continue; }

    log "=== killing app container on ${VICTIM} (${VICTIM_IP}) ==="
    ssh_to "${VICTIM_IP}" "docker stop ${PROJECT_REPO} >/dev/null" \
        || die "could not stop ${PROJECT_REPO} on ${VICTIM}"
    CURRENT_VICTIM="${VICTIM}"

    # Warmup window — let Caddy's active health probe (interval 2s, failing
    # threshold 2) mark the dead local upstream unhealthy before we measure.
    log "warmup: 6s for active health probe to quarantine dead upstream"
    sleep 6

    # 60 requests at 500ms intervals = 30s sustained probe window.
    log "sampling ${URL} 60x at 500ms while ${PROJECT_REPO} is dead on ${VICTIM}"
    SUCCESS=0; FAIL_COUNT=0
    PREV_COUNTER=${START}
    for i in $(seq 1 60); do
        CODE=$(curl -sk -o /tmp/_t5_resp.$$ -w '%{http_code}' --max-time 8 "${URL}" 2>/dev/null || echo "000")
        RESP=$(cat /tmp/_t5_resp.$$ 2>/dev/null); rm -f /tmp/_t5_resp.$$
        if [ "${CODE}" = "200" ]; then
            SUCCESS=$((SUCCESS+1))
            N=$(echo "${RESP}" | grep -oE '[0-9]+' | head -1)
            [ -n "${N}" ] && [ "${N}" -gt "${PREV_COUNTER}" ] && PREV_COUNTER=${N}
        else
            FAIL_COUNT=$((FAIL_COUNT+1))
            log "  [$i] FAIL code=${CODE} body='${RESP:0:120}'"
        fi
        sleep 0.5
    done
    log "results with ${VICTIM} app dead: ${SUCCESS}/60 success, ${FAIL_COUNT}/60 failed"

    if [ "${SUCCESS}" -eq 60 ]; then
        pass "60/60 succeeded with ${PROJECT_REPO} down on ${VICTIM} — Caddy multi-upstream failover OK"
    else
        fail "${SUCCESS}/60 succeeded with ${PROJECT_REPO} down on ${VICTIM} — Caddy failover NOT clean (was expecting 60/60)"
    fi

    # Restart the victim's app container and wait for it to report healthy.
    log "restarting ${PROJECT_REPO} on ${VICTIM}"
    ssh_to "${VICTIM_IP}" "docker start ${PROJECT_REPO} >/dev/null" \
        || die "could not restart ${PROJECT_REPO} on ${VICTIM}"

    log "waiting up to 45s for ${PROJECT_REPO} to be healthy on ${VICTIM}"
    RECOVERED=0
    for _ in $(seq 1 15); do
        sleep 3
        STATUS=$(ssh_to "${VICTIM_IP}" "docker inspect ${PROJECT_REPO} --format '{{.State.Health.Status}}' 2>/dev/null" || echo "unknown")
        if [ "${STATUS}" = "healthy" ]; then
            RECOVERED=1
            break
        fi
    done
    if [ "${RECOVERED}" != "1" ]; then
        fail "${PROJECT_REPO} on ${VICTIM} did not recover within 45s"
        CURRENT_VICTIM=""
        continue
    fi
    # Victim is back up; cleanup no longer needs to touch it.
    CURRENT_VICTIM=""

    # Post-recovery steady-state — all 20 must return 200. For counter-style
    # services we also require the counter to advance (proves we're hitting a
    # live app, not a stale/cached response). For static-response services
    # (COUNTER_AVAILABLE=0, decided during baseline) we require only 200s.
    if [ "${COUNTER_AVAILABLE}" = "1" ]; then
        log "post-recovery: 20 requests, expect all 200 + counter advancing"
    else
        log "post-recovery: 20 requests, expect all 200 (counter check skipped)"
    fi
    POST_SUCCESS=0
    POST_PREV=$(get_counter "${URL}")
    [ -n "${POST_PREV}" ] || POST_PREV=${PREV_COUNTER}
    for i in $(seq 1 20); do
        CODE=$(curl -sk -o /tmp/_t5_resp.$$ -w '%{http_code}' --max-time 8 "${URL}" 2>/dev/null || echo "000")
        RESP=$(cat /tmp/_t5_resp.$$ 2>/dev/null); rm -f /tmp/_t5_resp.$$
        if [ "${CODE}" = "200" ]; then
            if [ "${COUNTER_AVAILABLE}" = "1" ]; then
                N=$(echo "${RESP}" | grep -oE '[0-9]+' | head -1)
                if [ -n "${N}" ] && [ "${N}" -gt "${POST_PREV}" ]; then
                    POST_SUCCESS=$((POST_SUCCESS+1))
                    POST_PREV=${N}
                else
                    log "  [$i] 200 but counter stuck at ${N} (prev ${POST_PREV})"
                fi
            else
                POST_SUCCESS=$((POST_SUCCESS+1))
            fi
        else
            log "  [$i] FAIL code=${CODE}"
        fi
        sleep 0.5
    done
    if [ "${POST_SUCCESS}" -eq 20 ]; then
        if [ "${COUNTER_AVAILABLE}" = "1" ]; then
            pass "post-recovery on ${VICTIM}: 20/20 succeeded and counter advanced"
        else
            pass "post-recovery on ${VICTIM}: 20/20 succeeded (200 OK)"
        fi
    else
        fail "post-recovery on ${VICTIM}: only ${POST_SUCCESS}/20 met success criteria"
    fi

    START=${POST_PREV}
done

# Trap handles exit code.
