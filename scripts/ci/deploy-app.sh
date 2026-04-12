#!/bin/bash
# ---------------------------------------------------------------------------
# deploy-app.sh — deploys the app container to a single server with
# CANARY health checking and AUTO-ROLLBACK on failure.
#
# This script runs ON each app server (rishi-1 or rishi-2) over SSH from CI.
# CI calls it on rishi-1 first (the "canary"). If rishi-1 succeeds, CI then
# calls it on rishi-2. If rishi-1 FAILS, CI halts and rishi-2 keeps the old
# working code → users still get served via Cloudflare DNS round-robin.
#
# WHAT DOES THIS SCRIPT DO? (6 steps)
#   1. Record the currently-running image tag (for potential rollback)
#   2. Write secrets to disk + log in to GHCR
#   3. Run SQL migrations BEFORE starting the new app (expand-contract pattern)
#   4. Pull the new Docker image and start the container
#   5. Wait up to 90 seconds for the health check to pass
#   6a. On SUCCESS: save the tag as "last known good", update Caddy, exit 0
#   6b. On FAILURE: rollback to the previous image, exit 1
#
# REQUIRED ENVIRONMENT VARIABLES (passed by CI from GitHub Actions):
#   IMAGE_TAG    — git SHA for immutable image versioning
#   DATABASE_URL — server-specific (haproxy-rishi-1 or haproxy-rishi-2)
#   SENTRY_DSN   — Sentry project DSN (can be empty)
#   GITHUB_TOKEN — for GHCR docker login
#   GITHUB_ACTOR — GHCR username
#   APP_DIR      — path to the app directory on the server
#
# ROLLBACK MECHANISM:
#   .last_good_image_tag: a file written ONLY after a successful health check.
#   .previous_image_tag: the tag that was running before THIS deploy.
#   On failure, we prefer .last_good_image_tag (more reliable) over
#   .previous_image_tag (might be a previously failed deploy).
#   First-ever deploy on a fresh server has no rollback target — it will
#   exit non-zero and CI halts (no worse than before, much better otherwise).
# ---------------------------------------------------------------------------

# "set -e" = stop the script immediately if ANY command fails.
set -e

# Verify that the APP_DIR environment variable points to an existing directory.
# APP_DIR is where CI copied the compose file, config, and deploy scripts.
if [ ! -d "${APP_DIR}" ]; then
    echo "FATAL: APP_DIR does not exist: ${APP_DIR}"
    exit 1
fi
# Change into the app directory (all subsequent commands run from here)
cd "${APP_DIR}"

# Load project.config into the shell's environment.
# "set -a" = auto-export all variables (so docker compose can see them).
# "source" reads the file and executes each line (loading KEY=value pairs).
# "set +a" = turn off auto-export.
set -a
source ./project.config
set +a

# The file where we record the last KNOWN GOOD image tag (written only on success)
LAST_GOOD_FILE="${APP_DIR}/.last_good_image_tag"
echo "==> Deploying ${PROJECT_REPO} (new tag: ${IMAGE_TAG})"

# ----------------------------------------------------------------------
# Step 1: Record the currently-running image tag for potential rollback
# ----------------------------------------------------------------------
# Start with no previous tag
PREVIOUS_TAG=""
# Check if a container named "${PROJECT_REPO}" is currently running.
# "docker ps --filter" lists running containers matching the filter.
# "--format '{{.Image}}'" prints just the image name (e.g., ghcr.io/org/repo:abc123).
# "grep -q ." returns true if there's any output (a container is running).
if docker ps --filter "name=^${PROJECT_REPO}$" --format '{{.Image}}' | grep -q .; then
    # Extract just the tag part after the colon (e.g., "abc123" from "ghcr.io/org/repo:abc123").
    # "awk -F: '{print $NF}'" splits on ":" and takes the last field.
    PREVIOUS_TAG=$(docker ps --filter "name=^${PROJECT_REPO}$" --format '{{.Image}}' | head -1 | awk -F: '{print $NF}')
    echo "    currently running: ${PREVIOUS_TAG}"
fi

# Determine the best rollback target. The LAST KNOWN GOOD tag (from a previous
# successful deploy) is safer than the CURRENTLY RUNNING tag, because the
# currently-running one might itself be a failed deploy that Docker is
# trying to restart.
ROLLBACK_TAG=""
if [ -f "${LAST_GOOD_FILE}" ]; then
    # Read the last known good tag from disk
    ROLLBACK_TAG=$(cat "${LAST_GOOD_FILE}")
    echo "    last known good: ${ROLLBACK_TAG}"
elif [ -n "${PREVIOUS_TAG}" ]; then
    # Fall back to the currently-running tag if no .last_good_image_tag exists
    ROLLBACK_TAG="${PREVIOUS_TAG}"
    echo "    no .last_good_image_tag yet — fallback rollback target: ${ROLLBACK_TAG}"
else
    # This is the FIRST EVER deploy on this server — no rollback is possible
    echo "    no rollback target available (first ever deploy on this server)"
fi

# ----------------------------------------------------------------------
# Step 2: Write the DATABASE_URL secret to disk + log in to GHCR
# ----------------------------------------------------------------------
# Log in to GitHub Container Registry so Docker can pull our private images.
# We pipe the token via stdin (not as a command-line argument) for security.
echo "${GITHUB_TOKEN}" | docker login ghcr.io -u "${GITHUB_ACTOR}" --password-stdin >/dev/null

# Write the DATABASE_URL to a file that the app container reads at startup.
# WHY a file instead of an env var? Same reason as Swarm secrets — env vars
# are visible in `docker inspect`. Files in a chmod-700 directory are not.
if [ "${WITH_DATABASE:-true}" = "true" ]; then
    # Create the secrets directory (only the owner can read/write/enter it)
    mkdir -p secrets
    chmod 700 secrets
    # Write the DATABASE_URL to the file (no trailing newline: "-n")
    echo -n "${DATABASE_URL}" > secrets/database_url
    # 644 = owner can read/write, everyone can read.
    # WHY not 600? The container runs as non-root "appuser" (UID 1001),
    # so the file needs to be world-readable for appuser to access it.
    chmod 644 secrets/database_url
fi

# ----------------------------------------------------------------------
# Step 3: Run pending SQL migrations BEFORE starting the new app container
# ----------------------------------------------------------------------
# WHY BEFORE, NOT AFTER?
# If migrations ran after the new app starts, there's a window where the
# new code expects columns/tables that don't exist yet → app crashes.
# By running migrations first (against the old running app), we "expand"
# the schema to include everything the new code needs. The old app doesn't
# use the new columns, so it keeps working. The new app starts and finds
# everything it needs already in place. This is the "expand-contract"
# pattern for zero-downtime schema changes.
# Check if both the migrations/ directory and the migration script exist
if [ -d "${APP_DIR}/migrations" ] && [ -f "${APP_DIR}/scripts/ci/run-migrations.sh" ]; then
    echo "==> Running SQL migrations (before deploying new app code)..."
    # Run the migration script. "|| { ... }" means: if it fails, run the block.
    APP_DIR="${APP_DIR}" bash "${APP_DIR}/scripts/ci/run-migrations.sh" || {
        # Migration failed — do NOT deploy the new code (it might depend on
        # the migration that just failed). Exit with error to halt CI.
        echo "FATAL: migration failed — NOT deploying new app code"
        exit 1
    }
fi

# ----------------------------------------------------------------------
# Step 4: Pull the new image and start the container
# ----------------------------------------------------------------------
# "docker compose pull" downloads the new image from GHCR.
# SENTRY_DSN is passed as an env var because docker-compose.yml references it.
SENTRY_DSN="${SENTRY_DSN}" docker compose pull
# "docker compose up -d" starts the container in detached mode (background).
# If a container is already running, this replaces it with the new image.
SENTRY_DSN="${SENTRY_DSN}" docker compose up -d

# ----------------------------------------------------------------------
# Step 5: Wait for the health check to pass (up to 90 seconds)
# ----------------------------------------------------------------------
# Docker's built-in healthcheck (defined in docker-compose.yml) pings
# the app's /health endpoint. It reports one of: "starting", "healthy",
# "unhealthy", or the container might be "missing" (crashed and gone).
echo "==> Waiting for ${PROJECT_REPO} to become healthy (up to 90s)..."
HEALTHY=0
# Loop 30 times, sleeping 3 seconds each = 90 seconds max wait
for i in $(seq 1 30); do
    sleep 3
    # Ask Docker for the container's health status.
    # "docker inspect ... --format '{{.State.Health.Status}}'" extracts just
    # the health status string.
    # "2>/dev/null" suppresses errors. "|| echo 'missing'" handles the case
    # where the container doesn't exist at all.
    STATUS=$(docker inspect "${PROJECT_REPO}" --format '{{.State.Health.Status}}' 2>/dev/null || echo "missing")
    case "${STATUS}" in
        healthy)
            # The health check passed — the app is up and responding
            echo "    container reported healthy after $((i * 3))s"
            HEALTHY=1
            break
            ;;
        unhealthy)
            # The health check failed — the app started but isn't working
            echo "    container went UNHEALTHY after $((i * 3))s"
            break
            ;;
        starting)
            # Still in the start_period (the grace period before health checks begin).
            # This is normal — just wait.
            ;;
        missing)
            # The container isn't there at all (probably crashed on startup)
            echo "    container disappeared! (probably crashed and not restarting)"
            break
            ;;
        *)
            # Something unexpected — log it for debugging
            echo "    unexpected health status: ${STATUS}"
            ;;
    esac
done

# EXTRA CHECK: Even if Docker says "healthy", verify the FULL round-trip
# through Caddy (the reverse proxy). This catches cases where Docker thinks
# the container is healthy but Caddy can't reach it (network misconfiguration,
# Caddy crash, etc.). Caddy is what Cloudflare actually talks to.
if [ "${HEALTHY}" = "1" ]; then
    # curl the local Caddy with the project's Host header.
    # -sf: silent + fail on HTTP errors.
    # -m 5: timeout after 5 seconds.
    # -H "Host: ...": pretend we're coming from the internet (Caddy routes by hostname).
    # "http://localhost/health": hit the local Caddy (not the public URL).
    if ! curl -sf -m 5 -H "Host: ${PROJECT_DOMAIN}" "http://localhost/health" >/dev/null 2>&1; then
        echo "    docker says healthy but Caddy → app round trip FAILED"
        HEALTHY=0
    fi
fi

# ----------------------------------------------------------------------
# Step 6a: SUCCESS — record the new tag as "last known good" + update Caddy
# ----------------------------------------------------------------------
if [ "${HEALTHY}" = "1" ]; then
    # Write the successful image tag to disk. Future deploys will use this
    # as the rollback target if they fail.
    echo "${IMAGE_TAG}" > "${LAST_GOOD_FILE}"
    echo "==> Health check passed — recorded ${IMAGE_TAG} as last good tag"

    # ---- Update the Caddy reverse proxy snippet ----
    # Each project has a Caddy config file that tells Caddy:
    # "when someone requests <PROJECT_DOMAIN>, forward to this container"
    mkdir -p /home/deploy/caddy/conf.d
    # The final destination for this project's Caddy snippet
    SNIPPET_DEST="/home/deploy/caddy/conf.d/${PROJECT_REPO}.caddy"
    # Write to a temporary file first (atomic swap pattern — prevents serving
    # a half-written config if Caddy reloads mid-write)
    SNIPPET_TMP="${SNIPPET_DEST}.tmp"
    # "sed -e 's|old|new|g'" replaces placeholders in the template with real values.
    # The template has ${PROJECT_DOMAIN} and ${PROJECT_REPO} placeholders.
    sed -e "s|\${PROJECT_DOMAIN}|${PROJECT_DOMAIN}|g" \
        -e "s|\${PROJECT_REPO}|${PROJECT_REPO}|g" \
        caddy/snippet.caddy.template > "${SNIPPET_TMP}"

    # Validate that the EXISTING Caddy config is valid BEFORE we swap in the new snippet.
    # If Caddy's config was already broken, we don't want to add our snippet and
    # confuse the issue.
    docker exec caddy caddy validate --config /etc/caddy/Caddyfile || {
        echo "FATAL: existing Caddy config invalid before swap, aborting"
        rm -f "${SNIPPET_TMP}"
        exit 1
    }
    # Swap the temporary file into the real location (atomic on most filesystems)
    mv "${SNIPPET_TMP}" "${SNIPPET_DEST}"
    # Validate again WITH our new snippet to make sure WE didn't break anything
    docker exec caddy caddy validate --config /etc/caddy/Caddyfile || {
        echo "FATAL: new snippet broke Caddy config, removing"
        rm -f "${SNIPPET_DEST}"
        exit 1
    }
    # Tell Caddy to reload its config (picks up the new/updated snippet).
    # --force: reload even if the config hasn't changed (safety measure)
    docker exec caddy caddy reload --config /etc/caddy/Caddyfile --force
    echo "==> ${PROJECT_REPO} ${IMAGE_TAG} deployed and verified"
    # Exit 0 = success. CI will proceed to deploy the next server.
    exit 0
fi

# ----------------------------------------------------------------------
# Step 6b: FAILURE — auto-rollback to the previous working image
# ----------------------------------------------------------------------
echo "================================================================"
echo " DEPLOY FAILED HEALTH CHECK — rolling back"
echo " new tag (broken):  ${IMAGE_TAG}"
echo " rollback target:   ${ROLLBACK_TAG:-(none — first deploy)}"
echo "================================================================"

# Print diagnostic information so the CI logs are useful for debugging.
# Show the container's current state (running? exited? restarting?)
echo "=== container state ==="
docker ps -a --filter "name=^${PROJECT_REPO}$" --format '{{.Names}} {{.Status}}' || true
# Show the last 30 lines of container logs (usually shows the crash reason)
echo "=== last 30 lines of container logs ==="
docker logs --tail 30 "${PROJECT_REPO}" 2>&1 || true

# Check if we have a usable rollback target.
# Can't rollback if: no target exists, OR the target is the same as the broken one.
if [ -z "${ROLLBACK_TAG}" ] || [ "${ROLLBACK_TAG}" = "${IMAGE_TAG}" ]; then
    echo "FATAL: no usable rollback target — leaving the broken container in place."
    echo "       Manual intervention required."
    exit 1
fi

# Re-deploy the last known good (or previous) image.
# We override IMAGE_TAG with the rollback tag so docker-compose.yml pulls
# the old image instead of the broken new one.
echo "==> Re-deploying ${ROLLBACK_TAG}"
IMAGE_TAG="${ROLLBACK_TAG}" \
SENTRY_DSN="${SENTRY_DSN}" \
docker compose up -d

# Wait for the rolled-back container to become healthy (up to 60 seconds).
# It SHOULD be healthy since it was working before, but we verify anyway.
echo "==> Waiting for rolled-back container to recover..."
ROLLBACK_HEALTHY=0
for i in $(seq 1 20); do
    sleep 3
    STATUS=$(docker inspect "${PROJECT_REPO}" --format '{{.State.Health.Status}}' 2>/dev/null || echo "missing")
    # Short-circuit: if healthy, stop waiting
    [ "${STATUS}" = "healthy" ] && { ROLLBACK_HEALTHY=1; break; }
done

if [ "${ROLLBACK_HEALTHY}" = "1" ]; then
    echo "==> Rollback succeeded — running ${ROLLBACK_TAG}"
else
    echo "==> Rollback container is not yet healthy after 60s"
    echo "    The .last_good_image_tag is preserved. Investigate manually."
fi

# ALWAYS exit non-zero (error) so the CI workflow halts and does NOT touch
# the next server. The other app server (e.g., rishi-2) is still running
# the old healthy image, so Cloudflare DNS round-robin keeps serving traffic
# to users via that server. A failed canary on rishi-1 = zero user-visible outage.
exit 1
