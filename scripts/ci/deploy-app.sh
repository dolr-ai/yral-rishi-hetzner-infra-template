#!/bin/bash
# Runs ON each app server (rishi-1 or rishi-2) over SSH from CI.
# Deploys the project's app via docker-compose and updates its Caddy snippet.
#
# Required env vars (passed by CI from GitHub Actions):
#   IMAGE_TAG               — git SHA for immutable image versioning
#   DATABASE_URL            — server-specific (haproxy-rishi-1 or rishi-2)
#   SENTRY_DSN              — Sentry project DSN (can be empty)
#   GITHUB_TOKEN            — for GHCR docker login
#   GITHUB_ACTOR            — GHCR username
#   APP_DIR                 — path to the app dir on the server (contains
#                             project.config + docker-compose.yml + caddy/snippet.caddy.template)

set -e

cd "${APP_DIR}"

# Auto-export every line in project.config so docker compose interpolates ${VAR}
set -a
source ./project.config
set +a

echo "==> Deploying ${PROJECT_REPO} (${IMAGE_TAG})"

# Login to GHCR (private packages need auth for every pull)
echo "${GITHUB_TOKEN}" | docker login ghcr.io -u "${GITHUB_ACTOR}" --password-stdin

# Write DATABASE_URL to a secret file (mounted into the container at /run/secrets/database_url).
# This keeps the password out of `docker inspect`.
mkdir -p secrets
umask 077
echo -n "${DATABASE_URL}" > secrets/database_url

# Pull the new image and (re)create the container.
# IMAGE_TAG, IMAGE_REPO, PROJECT_REPO, OVERLAY_NETWORK etc. are already
# exported from project.config above, so the compose file's ${VAR} substitution
# works without additional flags.
SENTRY_DSN="${SENTRY_DSN}" docker compose pull
SENTRY_DSN="${SENTRY_DSN}" docker compose up -d

# ----------------------------------------------------------------------
# Caddy snippet (this project's only Caddy interaction).
# ----------------------------------------------------------------------
# We render caddy/snippet.caddy.template using sed (no envsubst dependency),
# write it as .tmp, validate Caddy is healthy, atomic-swap into place,
# revalidate, and reload. Each project owns ONLY its own snippet file.
mkdir -p /home/deploy/caddy/conf.d

SNIPPET_DEST="/home/deploy/caddy/conf.d/${PROJECT_REPO}.caddy"
SNIPPET_TMP="${SNIPPET_DEST}.tmp"

sed -e "s|\${PROJECT_DOMAIN}|${PROJECT_DOMAIN}|g" \
    -e "s|\${PROJECT_REPO}|${PROJECT_REPO}|g" \
    caddy/snippet.caddy.template > "${SNIPPET_TMP}"

# Validate BEFORE swap — abort if existing config is broken
docker exec caddy caddy validate --config /etc/caddy/Caddyfile || {
    echo "FATAL: existing Caddy config invalid before swap, aborting"
    rm -f "${SNIPPET_TMP}"
    exit 1
}

# Atomic swap
mv "${SNIPPET_TMP}" "${SNIPPET_DEST}"

# Validate AFTER swap — catches snippet syntax errors. If invalid, remove it.
docker exec caddy caddy validate --config /etc/caddy/Caddyfile || {
    echo "FATAL: new snippet broke Caddy config, removing it"
    rm -f "${SNIPPET_DEST}"
    exit 1
}

# Graceful reload
docker exec caddy caddy reload --config /etc/caddy/Caddyfile --force

echo "==> ${PROJECT_REPO} deployed and Caddy snippet updated."
