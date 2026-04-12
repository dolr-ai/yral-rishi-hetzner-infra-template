#!/bin/bash
# test_template_integrity.sh — fast structural sanity checks for the template.
#
# Run from CI and locally before pushing. Catches the kinds of mistakes that
# would only show up at deploy-time:
#   - project.config has all required keys
#   - servers.config has the IPs
#   - every infra file that uses ${VAR} references a key that exists
#   - docker compose config validates with project.config sourced
#   - all stack files are valid YAML
#   - shell scripts pass `bash -n` syntax check

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "  ok: $1"; }

echo "==> 1. project.config has all required keys"
REQUIRED=(PROJECT_NAME PROJECT_DOMAIN PROJECT_REPO POSTGRES_DB PATRONI_SCOPE
          ETCD_TOKEN SWARM_STACK OVERLAY_NETWORK IMAGE_REPO PATRONI_IMAGE_REPO
          WITH_DATABASE)
for k in "${REQUIRED[@]}"; do
    grep -q "^${k}=" project.config || fail "project.config missing $k"
done
pass "project.config"

echo "==> 2. servers.config has IPs and DEPLOY_USER"
for k in SERVER_1_IP SERVER_2_IP SERVER_3_IP DEPLOY_USER; do
    grep -q "^${k}=" servers.config || fail "servers.config missing $k"
done
pass "servers.config"

echo "==> 3. docker-compose.yml validates with project.config sourced"
set -a
source project.config
source servers.config
set +a
export IMAGE_TAG=test
docker compose -f docker-compose.yml config >/dev/null 2>&1 || \
    fail "docker-compose.yml fails to validate"
pass "docker-compose.yml"

echo "==> 4. Stack files are valid YAML (only when WITH_DATABASE=true)"
if [ "${WITH_DATABASE}" = "true" ]; then
    for f in etcd/stack.yml patroni/stack.yml haproxy/stack.yml; do
        [ -f "$f" ] || fail "missing $f (WITH_DATABASE=true but file absent)"
        # Use docker compose's built-in YAML parser if PyYAML isn't installed.
        if python3 -c "import yaml" 2>/dev/null; then
            python3 -c "import yaml; yaml.safe_load(open('$f'))" || fail "invalid YAML: $f"
        else
            docker compose -f "$f" config >/dev/null 2>&1 || \
                fail "invalid YAML or compose schema: $f"
        fi
    done
    pass "stack files"
else
    pass "stateless mode — skipping stack file checks"
fi

echo "==> 5. Shell scripts pass syntax check"
for s in scripts/ci/*.sh scripts/*.sh local/*.sh; do
    [ -f "$s" ] || continue
    bash -n "$s" || fail "syntax error in $s"
done
pass "shell scripts"

echo "==> 6. Caddy snippet template references valid vars"
grep -q '${PROJECT_DOMAIN}' caddy/snippet.caddy.template || \
    fail "caddy/snippet.caddy.template missing \${PROJECT_DOMAIN}"
grep -q '${PROJECT_REPO}' caddy/snippet.caddy.template || \
    fail "caddy/snippet.caddy.template missing \${PROJECT_REPO}"
pass "caddy snippet"

echo "==> 7. No leftover offline-testing references"
if grep -rIn --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=tests \
    --exclude='*.md' 'offline-testing\|rishi_offline_testing' . 2>/dev/null; then
    fail "found stale references to old project name"
fi
pass "no stale names"

echo "==> 8. Naming consistency — Dockerfiles match project.config"
# The LABEL in each Dockerfile should reference THIS project's repo, not
# the template's. This catches the case where init-from-template.sh didn't
# update the Dockerfiles (or a new Dockerfile was added without the right name).
for df in Dockerfile backup/Dockerfile patroni/Dockerfile; do
    [ -f "$df" ] || continue
    if grep -q "org.opencontainers.image.source" "$df"; then
        if ! grep -q "dolr-ai/${PROJECT_REPO}" "$df"; then
            fail "$df has wrong image.source label — expected dolr-ai/${PROJECT_REPO}"
        fi
    fi
done
pass "Dockerfile labels match project.config"

echo "==> 9. Naming consistency — docs reference this project, not the template"
# Skip this check on the TEMPLATE ITSELF (PROJECT_NAME contains "hetzner-infra-template").
# Only run on services created FROM the template.
if [ "${PROJECT_NAME}" != "rishi-hetzner-infra-template" ]; then
    STALE_REFS=$(grep -rIn --include='*.md' --exclude-dir=.git \
        'rishi-hetzner-infra-template' . 2>/dev/null \
        | grep -v 'NAMING-CONVENTIONS.md' \
        | grep -v 'init-from-template.sh' \
        | grep -v 'TEMPLATE.md' || true)
    if [ -n "$STALE_REFS" ]; then
        echo "$STALE_REFS"
        fail "found template name references in docs — run: bash scripts/init-from-template.sh ${PROJECT_NAME}"
    fi
    pass "no template name leaks in docs"
else
    pass "skipping (this IS the template)"
fi

echo "==> 10. Backup config — S3 endpoint is not a placeholder"
# project.config ships with a placeholder endpoint. If backup.yml runs
# without a real endpoint, it silently fails. This check catches it early.
if [ "${WITH_DATABASE}" = "true" ]; then
    S3_EP=$(grep '^BACKUP_S3_ENDPOINT=' project.config | cut -d= -f2)
    if [ -z "$S3_EP" ] || [ "$S3_EP" = "https://REPLACE_ME" ]; then
        fail "BACKUP_S3_ENDPOINT is empty or still a placeholder — backups won't work"
    fi
    pass "backup S3 endpoint configured"
else
    pass "stateless mode — skipping backup check"
fi

echo
echo "All template integrity checks passed."
