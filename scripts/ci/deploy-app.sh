#!/bin/bash
# Runs ON each app server (rishi-1 or rishi-2) over SSH from CI.
# Deploys the project's app via docker-compose with CANARY + AUTO-ROLLBACK.
#
# Required env vars (passed by CI from GitHub Actions):
#   IMAGE_TAG               — git SHA for immutable image versioning
#   DATABASE_URL            — server-specific (haproxy-rishi-1 or rishi-2)
#   SENTRY_DSN              — Sentry project DSN (can be empty)
#   GITHUB_TOKEN            — for GHCR docker login
#   GITHUB_ACTOR            — GHCR username
#   APP_DIR                 — path to the app dir on the server
#
# Lifecycle:
#   1. Record the currently-running image tag → /home/deploy/<repo>/.previous_image_tag
#      (used for auto-rollback if the new deploy fails its health check).
#   2. Write secrets, login to GHCR, pull the new image.
#   3. `docker compose up -d` to start the new container.
#   4. Wait up to 60s for Docker's healthcheck to report `healthy`. If it
#      reports `unhealthy` OR doesn't reach `healthy` within 60s → ROLLBACK.
#   5. On success: write the new tag → /home/deploy/<repo>/.last_good_image_tag,
#      update Caddy snippet, exit 0. The CI workflow then deploys the next
#      server.
#   6. On failure: re-deploy the .previous_image_tag (or .last_good_image_tag
#      if available) and exit non-0. The CI workflow halts BEFORE touching the
#      next server, so the other server keeps serving the old healthy image
#      via Cloudflare DNS round-robin.
#
# Rollback file lives at $APP_DIR/.last_good_image_tag — written ONLY after a
# successful health verification. The very first deploy on a fresh server has
# no .last_good_image_tag, so a first-deploy failure can't be rolled back —
# it will exit non-0 and CI halts before touching the second server (no worse
# than the old behavior in that one edge case, much better in every other case).

set -e

if [ ! -d "${APP_DIR}" ]; then
    echo "FATAL: APP_DIR does not exist: ${APP_DIR}"
    exit 1
fi
cd "${APP_DIR}"

# Auto-export every line in project.config so docker compose interpolates ${VAR}
set -a
source ./project.config
set +a

LAST_GOOD_FILE="${APP_DIR}/.last_good_image_tag"
echo "==> Deploying ${PROJECT_REPO} (new tag: ${IMAGE_TAG})"

# ----------------------------------------------------------------------
# 1. Record currently-running tag for potential rollback
# ----------------------------------------------------------------------
PREVIOUS_TAG=""
if docker ps --filter "name=^${PROJECT_REPO}$" --format '{{.Image}}' | grep -q .; then
    PREVIOUS_TAG=$(docker ps --filter "name=^${PROJECT_REPO}$" --format '{{.Image}}' | head -1 | awk -F: '{print $NF}')
    echo "    currently running: ${PREVIOUS_TAG}"
fi

# Prefer the LAST KNOWN GOOD tag from disk if it exists — that's safer than
# the currently-running tag, because the currently-running one might be
# a previous failed deploy that the host is in the middle of restarting.
ROLLBACK_TAG=""
if [ -f "${LAST_GOOD_FILE}" ]; then
    ROLLBACK_TAG=$(cat "${LAST_GOOD_FILE}")
    echo "    last known good: ${ROLLBACK_TAG}"
elif [ -n "${PREVIOUS_TAG}" ]; then
    ROLLBACK_TAG="${PREVIOUS_TAG}"
    echo "    no .last_good_image_tag yet — fallback rollback target: ${ROLLBACK_TAG}"
else
    echo "    no rollback target available (first ever deploy on this server)"
fi

# ----------------------------------------------------------------------
# 2. Write DATABASE_URL secret + GHCR login
# ----------------------------------------------------------------------
echo "${GITHUB_TOKEN}" | docker login ghcr.io -u "${GITHUB_ACTOR}" --password-stdin >/dev/null

if [ "${WITH_DATABASE:-true}" = "true" ]; then
    mkdir -p secrets
    chmod 700 secrets
    echo -n "${DATABASE_URL}" > secrets/database_url
    chmod 644 secrets/database_url    # so the container's non-root appuser can read it
fi

# ----------------------------------------------------------------------
# 3. Run pending SQL migrations BEFORE starting the new app container
# ----------------------------------------------------------------------
# WHY BEFORE, NOT AFTER?
# If migrations ran after the new app starts, there's a window where the
# new code expects columns/tables that don't exist yet → app crashes.
# By running migrations first (against the old running app), we "expand"
# the schema to include everything the new code needs. The old app doesn't
# use the new columns, so it keeps working. The new app starts and finds
# everything it needs already in place. This is the "expand-contract"
# pattern for zero-downtime schema changes.
if [ -d "${APP_DIR}/migrations" ] && [ -f "${APP_DIR}/scripts/ci/run-migrations.sh" ]; then
    echo "==> Running SQL migrations (before deploying new app code)..."
    APP_DIR="${APP_DIR}" bash "${APP_DIR}/scripts/ci/run-migrations.sh" || {
        echo "FATAL: migration failed — NOT deploying new app code"
        exit 1
    }
fi

# ----------------------------------------------------------------------
# 4. Pull and start the NEW image
# ----------------------------------------------------------------------
SENTRY_DSN="${SENTRY_DSN}" docker compose pull
SENTRY_DSN="${SENTRY_DSN}" docker compose up -d

# ----------------------------------------------------------------------
# 4. WAIT for healthy (the critical missing piece)
# ----------------------------------------------------------------------
# Polls Docker's healthcheck (defined in docker-compose.yml as a python
# urllib request to /health). The compose healthcheck has interval=30s, so
# we may need to wait up to ~90s for the FIRST healthy report.
echo "==> Waiting for ${PROJECT_REPO} to become healthy (up to 90s)..."
HEALTHY=0
for i in $(seq 1 30); do
    sleep 3
    STATUS=$(docker inspect "${PROJECT_REPO}" --format '{{.State.Health.Status}}' 2>/dev/null || echo "missing")
    case "${STATUS}" in
        healthy)
            echo "    container reported healthy after $((i * 3))s"
            HEALTHY=1
            break
            ;;
        unhealthy)
            echo "    container went UNHEALTHY after $((i * 3))s"
            break
            ;;
        starting)
            # Still inside the start_period — that's fine
            ;;
        missing)
            echo "    container disappeared! (probably crashed and not restarting)"
            break
            ;;
        *)
            echo "    unexpected health status: ${STATUS}"
            ;;
    esac
done

# Also do an in-band curl to the local Caddy as a final sanity check.
# Caddy returning 200 is the only thing the Cloudflare side actually sees.
if [ "${HEALTHY}" = "1" ]; then
    if ! curl -sf -m 5 -H "Host: ${PROJECT_DOMAIN}" "http://localhost/health" >/dev/null 2>&1; then
        echo "    docker says healthy but Caddy → app round trip FAILED"
        HEALTHY=0
    fi
fi

# ----------------------------------------------------------------------
# 5a. SUCCESS — record the new tag, update Caddy snippet
# ----------------------------------------------------------------------
if [ "${HEALTHY}" = "1" ]; then
    echo "${IMAGE_TAG}" > "${LAST_GOOD_FILE}"
    echo "==> Health check passed — recorded ${IMAGE_TAG} as last good tag"

    # ---- Caddy snippet ----
    mkdir -p /home/deploy/caddy/conf.d
    SNIPPET_DEST="/home/deploy/caddy/conf.d/${PROJECT_REPO}.caddy"
    SNIPPET_TMP="${SNIPPET_DEST}.tmp"
    sed -e "s|\${PROJECT_DOMAIN}|${PROJECT_DOMAIN}|g" \
        -e "s|\${PROJECT_REPO}|${PROJECT_REPO}|g" \
        caddy/snippet.caddy.template > "${SNIPPET_TMP}"

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
    echo "==> ${PROJECT_REPO} ${IMAGE_TAG} deployed and verified"
    exit 0
fi

# ----------------------------------------------------------------------
# 5b. FAILURE — auto-rollback
# ----------------------------------------------------------------------
echo "================================================================"
echo " DEPLOY FAILED HEALTH CHECK — rolling back"
echo " new tag (broken):  ${IMAGE_TAG}"
echo " rollback target:   ${ROLLBACK_TAG:-(none — first deploy)}"
echo "================================================================"

# Show what the container is doing so the CI logs are useful for debugging
echo "=== container state ==="
docker ps -a --filter "name=^${PROJECT_REPO}$" --format '{{.Names}} {{.Status}}' || true
echo "=== last 30 lines of container logs ==="
docker logs --tail 30 "${PROJECT_REPO}" 2>&1 || true

if [ -z "${ROLLBACK_TAG}" ] || [ "${ROLLBACK_TAG}" = "${IMAGE_TAG}" ]; then
    echo "FATAL: no usable rollback target — leaving the broken container in place."
    echo "       Manual intervention required."
    exit 1
fi

echo "==> Re-deploying ${ROLLBACK_TAG}"
IMAGE_TAG="${ROLLBACK_TAG}" \
SENTRY_DSN="${SENTRY_DSN}" \
docker compose up -d

# Wait briefly for the rollback to come back up
echo "==> Waiting for rolled-back container to recover..."
ROLLBACK_HEALTHY=0
for i in $(seq 1 20); do
    sleep 3
    STATUS=$(docker inspect "${PROJECT_REPO}" --format '{{.State.Health.Status}}' 2>/dev/null || echo "missing")
    [ "${STATUS}" = "healthy" ] && { ROLLBACK_HEALTHY=1; break; }
done

if [ "${ROLLBACK_HEALTHY}" = "1" ]; then
    echo "==> Rollback succeeded — running ${ROLLBACK_TAG}"
else
    echo "==> Rollback container is not yet healthy after 60s"
    echo "    The .last_good_image_tag is preserved. Investigate manually."
fi

# Always exit non-zero so the CI workflow halts and does NOT touch the
# next server. The other app server is still running the old healthy
# image, so Cloudflare DNS round-robin keeps serving traffic.
exit 1
