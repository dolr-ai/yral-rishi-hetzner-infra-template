#!/bin/bash
# Run all 4 integration tests in order. MANUAL ONLY — these need SSH access
# to the live Hetzner cluster and may temporarily disrupt traffic.
#
# Usage:
#   bash tests/integration/run_all.sh                          # against the current repo's PROJECT_DOMAIN
#   bash tests/integration/run_all.sh some.other.domain.com    # override the domain
#
# Exit code: 0 if all 4 pass, 1 otherwise.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOMAIN="${1:-}"

if [ -t 1 ]; then
    G='\033[0;32m'; R='\033[0;31m'; B='\033[0;34m'; N='\033[0m'
else
    G=''; R=''; B=''; N=''
fi

echo -e "${B}=========================================================${N}"
echo -e "${B} dolr-ai infra-template integration test suite${N}"
echo -e "${B} target: ${DOMAIN:-(repo default from project.config)}${N}"
echo -e "${B}=========================================================${N}"

TESTS=(
    test_01_server_failover.sh
    test_02_server_and_leader_failover.sh
    test_03_project_isolation.sh
    test_04_image_parity.sh
)

PASS=0; FAIL=0; FAILED_TESTS=""
for t in "${TESTS[@]}"; do
    echo
    echo -e "${B}---- ${t} ----${N}"
    if bash "${SCRIPT_DIR}/${t}" "${DOMAIN}"; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        FAILED_TESTS="${FAILED_TESTS} ${t}"
    fi
done

echo
echo -e "${B}=========================================================${N}"
echo -e "${B} Summary: ${G}${PASS} passed${N}, ${R}${FAIL} failed${N}"
if [ "${FAIL}" -gt 0 ]; then
    echo -e "${R} Failed tests:${FAILED_TESTS}${N}"
    exit 1
fi
echo -e "${G} All integration tests passed.${N}"
echo -e "${B}=========================================================${N}"
