#!/bin/bash
# Shared helpers for tests/integration/* scripts.
#
# Source this from each test:   source "$(dirname "$0")/lib.sh"
#
# Provides:
#   - PROJECT_DOMAIN  (set from $1)
#   - SSH_KEY, SERVER_1_IP, SERVER_2_IP, SERVER_3_IP, DEPLOY_USER (from servers.config)
#   - PROJECT_NAME, SWARM_STACK, etc. (from project.config)
#   - ssh_to <ip> <cmd>            — ssh as deploy user with the CI key
#   - curl_with_status <url>       — prints "<http_code> <body>"
#   - get_patroni_leader            — prints "<server_n> <container_name>"
#   - get_counter <url>             — extracts the integer from /'s response
#   - log / pass / fail / die       — colored output + exit handling
#   - ALL_PASS / ALL_FAIL bookkeeping for the runner

set -uo pipefail

# ---- Config loading ----
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ -f "${REPO_ROOT}/project.config" ] || { echo "FATAL: project.config not found at ${REPO_ROOT}"; exit 1; }
[ -f "${REPO_ROOT}/servers.config" ] || { echo "FATAL: servers.config not found at ${REPO_ROOT}"; exit 1; }

set -a
# shellcheck disable=SC1091
source "${REPO_ROOT}/project.config"
# shellcheck disable=SC1091
source "${REPO_ROOT}/servers.config"
set +a

# Expand ~ in SSH_KEY_PATH
SSH_KEY="${SSH_KEY_PATH/#\~/$HOME}"
[ -f "${SSH_KEY}" ] || { echo "FATAL: CI key not found at ${SSH_KEY}"; exit 1; }

# ---- PROJECT_DOMAIN: arg override (so we can test the test service) ----
if [ -n "${1:-}" ]; then
    PROJECT_DOMAIN="$1"
fi

# ---- Output helpers ----
if [ -t 1 ]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'; C_RESET='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_RESET=''
fi

log()  { echo -e "${C_BLUE}[$(basename "${0}")]${C_RESET} $*"; }
pass() { echo -e "${C_GREEN}  PASS${C_RESET}: $*"; }
fail() { echo -e "${C_RED}  FAIL${C_RESET}: $*"; FAILED=1; }
die()  { echo -e "${C_RED}FATAL${C_RESET}: $*" >&2; exit 1; }

FAILED=0

# ---- SSH wrapper ----
ssh_to() {
    local ip="$1"; shift
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o LogLevel=ERROR "${DEPLOY_USER}@${ip}" "$@"
}

# ---- HTTP helpers ----
curl_with_status() {
    # Prints "<http_code> <body>" on stdout. Body may contain spaces.
    curl -sk -o - -w '\n%{http_code}' --max-time 8 "$1" 2>/dev/null
}

curl_ok() {
    # Returns 0 if URL returned 200 with a body containing "Person".
    local out
    out=$(curl -sk --max-time 8 "$1" 2>/dev/null) || return 1
    echo "$out" | grep -q '"message".*Person' || return 1
    return 0
}

get_counter() {
    # Extract the integer N from {"message":"Hello World Person N"}
    curl -sk --max-time 8 "$1" 2>/dev/null | sed -n 's/.*Person \([0-9]*\).*/\1/p'
}

# ---- Patroni helpers ----
get_patroni_leader() {
    # Prints two space-separated values: "<server_n> <full-container-name>"
    # e.g. "rishi-2 patroni-rishi-2"
    local list
    list=$(ssh_to "${SERVER_1_IP}" "C=\$(docker ps -qf name=patroni-rishi-1 | head -1); docker exec \"\$C\" patronictl -c /etc/patroni.yml list" 2>/dev/null) || return 1
    local leader_row
    leader_row=$(echo "$list" | grep -E '\| Leader ')
    [ -z "$leader_row" ] && { echo "no leader"; return 1; }
    local member
    member=$(echo "$leader_row" | awk -F'|' '{gsub(/ /,"",$2); print $2}')
    echo "${member} patroni-${member}"
}

# Translate "rishi-1" → SERVER_1_IP, etc.
server_ip_for() {
    case "$1" in
        rishi-1) echo "${SERVER_1_IP}" ;;
        rishi-2) echo "${SERVER_2_IP}" ;;
        rishi-3) echo "${SERVER_3_IP}" ;;
        *) echo ""; return 1 ;;
    esac
}
