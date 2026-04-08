#!/bin/bash
# Test 4 — Local Mac docker image == prod docker image (byte-identical sources).
#
# Builds the local image (or reuses the existing :local tag), then compares
# md5sums of source files + sorted pip freeze inside both images.
#
# We don't compare image SHAs directly because Mac arm64 vs CI x86_64 always
# produces different layer SHAs. What we DO compare is the content that
# actually matters: the application code and the resolved Python dep set.
#
# Usage: bash test_04_image_parity.sh [PROJECT_DOMAIN]

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh" "${1:-}"

log "Test 4: image parity (local vs prod) for ${PROJECT_REPO}"

LOCAL_TAG="${IMAGE_REPO}:local"
HASH_CMD='set -e; for f in main.py database.py infra/sentry.py infra/vault.py infra/uptime_kuma.py; do
    if [ -f "$f" ]; then md5sum "$f"; else echo "MISSING $f"; fi
done; pip freeze 2>/dev/null | sort | md5sum | sed "s/-$/pip-freeze/"'

# 1. Make sure the local image exists
if ! docker image inspect "${LOCAL_TAG}" >/dev/null 2>&1; then
    log "local image ${LOCAL_TAG} not found; building from ${REPO_ROOT}"
    docker build --network=host -t "${LOCAL_TAG}" "${REPO_ROOT}" >/dev/null || die "local build failed"
fi

# 2. Hash inside the local image
log "computing hashes inside ${LOCAL_TAG}"
LOCAL_HASHES=$(docker run --rm --entrypoint sh "${LOCAL_TAG}" -c "${HASH_CMD}" 2>&1) || \
    die "could not hash local image"
echo "${LOCAL_HASHES}" | sed 's/^/  /'
echo

# 3. Hash inside the running prod container on rishi-1
log "computing hashes inside the running prod container on rishi-1"
PROD_OUT=$(ssh_to "${SERVER_1_IP}" "C=\$(docker ps -qf name=${PROJECT_REPO} | head -1); \
    [ -z \"\$C\" ] && { echo NO_RUNNING_CONTAINER; exit 1; }; \
    docker exec \"\$C\" sh -c '${HASH_CMD}'") || die "could not hash prod image"
echo "${PROD_OUT}" | sed 's/^/  /'
echo

# 4. Diff
DIFF=$(diff <(echo "${LOCAL_HASHES}") <(echo "${PROD_OUT}") || true)
if [ -z "${DIFF}" ]; then
    pass "all hashes byte-identical (local == prod)"
else
    fail "image content drift detected:"
    echo "${DIFF}" | sed 's/^/    /'
fi

# 5. Bonus: running tag matches HEAD (only meaningful for the template repo,
#    not for cloned services that haven't pushed yet)
log "bonus: running prod image tag vs git HEAD"
if [ -d "${REPO_ROOT}/.git" ]; then
    HEAD_SHA=$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo "")
    PROD_TAG=$(ssh_to "${SERVER_1_IP}" "docker ps --filter name=${PROJECT_REPO} --format '{{.Image}}' | head -1 | awk -F: '{print \$NF}'") || PROD_TAG=""
    if [ -n "${HEAD_SHA}" ] && [ -n "${PROD_TAG}" ]; then
        if [ "${HEAD_SHA}" = "${PROD_TAG}" ]; then
            pass "  prod tag ${PROD_TAG} == HEAD"
        else
            log "  prod tag=${PROD_TAG}, HEAD=${HEAD_SHA} (drift — push not yet deployed?)"
        fi
    fi
fi

[ "${FAILED}" = "1" ] && exit 1
exit 0
