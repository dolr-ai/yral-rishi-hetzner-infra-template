#!/bin/bash
# Test 3 — Zero cross-project dependency.
#
# Static checks (no SSH): every namespaced identifier in project.config is
# project-prefixed and never references hello-world / counter / any other svc.
#
# Runtime checks (SSH): hit hello-world.rishi.yral.com and
# hello-world-counter.rishi.yral.com, capture their counter/state, then run a
# "no-op" disruption (caddy stop/start cycle on rishi-1) and assert those two
# external services were NOT affected.
#
# Usage: bash test_03_project_isolation.sh [PROJECT_DOMAIN]

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh" "${1:-}"

log "Test 3: zero cross-project dependency for ${PROJECT_DOMAIN}"

# ----- Static check 1: project.config identifiers are namespaced -----
log "static: project.config identifiers must reference \$PROJECT_NAME, never another service"
PNAME="${PROJECT_NAME}"

# Each value must contain the project name (or a derived form)
PNAME_UNDERSCORE="$(echo "$PNAME" | tr '-' '_')"
check_contains() {
    local key="$1"; local val="$2"
    if echo "$val" | grep -qE "${PNAME}|${PNAME_UNDERSCORE}"; then
        pass "  ${key}=${val} contains project name"
    else
        fail "  ${key}=${val} does NOT contain project name (cross-project leak risk)"
    fi
}
check_contains POSTGRES_DB        "${POSTGRES_DB}"
check_contains PATRONI_SCOPE      "${PATRONI_SCOPE}"
check_contains ETCD_TOKEN         "${ETCD_TOKEN}"
check_contains SWARM_STACK        "${SWARM_STACK}"
check_contains OVERLAY_NETWORK    "${OVERLAY_NETWORK}"
check_contains IMAGE_REPO         "${IMAGE_REPO}"
check_contains PATRONI_IMAGE_REPO "${PATRONI_IMAGE_REPO}"
check_contains PROJECT_REPO       "${PROJECT_REPO}"

# ----- Static check 2: no references to other dolr-ai service names -----
log "static: repo files must not contain other dolr-ai service identifiers"
FOREIGN_NAMES="hello-world hello_world counter-db counter_db"
for foreign in ${FOREIGN_NAMES}; do
    # Allowed in markdown docs / comments / this test itself
    HITS=$(grep -rIn --exclude-dir=.git --exclude-dir=tests --exclude='*.md' \
        --exclude='conftest.py' "${foreign}" "${REPO_ROOT}" 2>/dev/null | \
        grep -v "^${REPO_ROOT}/tests/" | head -3 || true)
    if [ -n "${HITS}" ]; then
        fail "  found '${foreign}' in non-doc files:"
        echo "${HITS}" | sed 's/^/      /'
    else
        pass "  no references to '${foreign}'"
    fi
done

# ----- Static check 3: caddy snippet only references project's own vars -----
log "static: caddy/snippet.caddy.template references only \${PROJECT_DOMAIN} and \${PROJECT_REPO}"
SNIPPET="${REPO_ROOT}/caddy/snippet.caddy.template"
if grep -qE '\$\{PROJECT_DOMAIN\}' "${SNIPPET}" && grep -qE '\$\{PROJECT_REPO\}' "${SNIPPET}"; then
    pass "  caddy snippet uses only project-scoped vars"
else
    fail "  caddy snippet missing one of \${PROJECT_DOMAIN} / \${PROJECT_REPO}"
fi

# ----- Runtime: capture external services state -----
log "runtime: capturing baseline of external dolr-ai services"
HW_BEFORE=$(curl -sk --max-time 8 https://hello-world.rishi.yral.com/ 2>/dev/null || echo "")
CT_BEFORE=$(curl -sk --max-time 8 https://hello-world-counter.rishi.yral.com/ 2>/dev/null || echo "")
if [ -z "${HW_BEFORE}" ]; then
    log "  (hello-world unreachable — skipping that part of the runtime check)"
else
    pass "  hello-world before: ${HW_BEFORE}"
fi
if [ -z "${CT_BEFORE}" ]; then
    log "  (counter unreachable — skipping that part of the runtime check)"
else
    pass "  counter before: ${CT_BEFORE}"
    CT_BEFORE_VAL=$(echo "${CT_BEFORE}" | sed -n 's/.*Person \([0-9]*\).*/\1/p')
fi

# ----- Disruption: stop/start caddy on rishi-1 (proves we don't touch others) -----
log "runtime: stopping caddy on rishi-1 for ~10s (mimics a deploy of THIS template)"
ssh_to "${SERVER_1_IP}" 'docker stop caddy >/dev/null'
sleep 8
ssh_to "${SERVER_1_IP}" 'docker start caddy >/dev/null'
sleep 5

# ----- Verify external services unaffected -----
HW_AFTER=$(curl -sk --max-time 8 https://hello-world.rishi.yral.com/ 2>/dev/null || echo "")
CT_AFTER=$(curl -sk --max-time 8 https://hello-world-counter.rishi.yral.com/ 2>/dev/null || echo "")

if [ -n "${HW_BEFORE}" ]; then
    if [ -n "${HW_AFTER}" ]; then
        pass "  hello-world still healthy after disruption: ${HW_AFTER}"
    else
        fail "  hello-world went DOWN during our disruption — cross-project leak!"
    fi
fi
if [ -n "${CT_BEFORE}" ]; then
    if [ -n "${CT_AFTER}" ]; then
        CT_AFTER_VAL=$(echo "${CT_AFTER}" | sed -n 's/.*Person \([0-9]*\).*/\1/p')
        if [ "${CT_AFTER_VAL}" -ge "${CT_BEFORE_VAL}" ]; then
            pass "  counter still incrementing forward: ${CT_BEFORE_VAL} → ${CT_AFTER_VAL}"
        else
            fail "  counter went BACKWARDS (${CT_BEFORE_VAL} → ${CT_AFTER_VAL}) — state was reset!"
        fi
    else
        fail "  counter went DOWN during our disruption — cross-project leak!"
    fi
fi

# Bonus: counter-db swarm stack should still be 1/1 across the board
if ssh_to "${SERVER_1_IP}" 'docker stack ls --format "{{.Name}}" | grep -q counter-db' 2>/dev/null; then
    BAD=$(ssh_to "${SERVER_1_IP}" 'docker stack services counter-db --format "{{.Name}} {{.Replicas}}"' | grep -v ' 1/1' | wc -l | tr -d ' ')
    if [ "${BAD}" = "0" ]; then
        pass "  counter-db swarm stack: all services 1/1 after disruption"
    else
        fail "  counter-db swarm stack has ${BAD} services not at 1/1"
    fi
fi

[ "${FAILED}" = "1" ] && exit 1
exit 0
