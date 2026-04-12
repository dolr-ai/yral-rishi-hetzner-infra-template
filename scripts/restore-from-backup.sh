#!/bin/bash
# =============================================================================
# restore-from-backup.sh — restore the database from a backup in S3.
#
# This script triggers the restore.yml GitHub Actions workflow, which:
#   1. SSHes into rishi-1 (the Swarm manager)
#   2. Downloads the backup from S3 using credentials from GitHub Secrets
#   3. Drops + recreates the database
#   4. Restores the SQL dump
#   5. Re-runs pending migrations
#   6. Restarts app containers on both servers
#
# WHY A CI WORKFLOW (not a local script)?
# S3 credentials (BACKUP_S3_ACCESS_KEY + BACKUP_S3_SECRET_KEY) are stored
# in GitHub Secrets — the most secure location. They're never stored on
# your local Mac or in code. The CI workflow reads them directly from
# GitHub Secrets and passes them to the server.
#
# Usage:
#   bash scripts/restore-from-backup.sh --latest           # restore latest
#   bash scripts/restore-from-backup.sh --date 2026-04-12  # restore by date
#   bash scripts/restore-from-backup.sh --file local.sql.gz # restore local file
#
# For --latest and --date: triggers the restore.yml workflow in GitHub Actions.
# For --file: uploads the file to the server and restores directly (no S3).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

set -a
source "${REPO_ROOT}/project.config"
source "${REPO_ROOT}/servers.config"
set +a

SSH_KEY="${SSH_KEY_PATH/#\~/$HOME}"
ORG="dolr-ai"

# Args
DATE=""
LATEST="false"
LOCAL_FILE=""
ASSUME_YES="false"
while [ $# -gt 0 ]; do
    case "$1" in
        --date)   DATE="$2"; shift 2 ;;
        --latest) LATEST="true"; shift ;;
        --file)   LOCAL_FILE="$2"; shift 2 ;;
        --yes)    ASSUME_YES="true"; shift ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# ----- PROJECT ISOLATION GUARD -----
if [ -z "${PROJECT_REPO}" ] || [ "${PROJECT_REPO}" = "yral-" ]; then
    echo "FATAL: PROJECT_REPO is empty or invalid — refusing to run"
    exit 1
fi

# =================================================================
# PATH 1: Restore from S3 via GitHub Actions workflow
# (--latest or --date) — S3 creds come from GitHub Secrets
# =================================================================
if [ -z "${LOCAL_FILE}" ]; then
    TARGET="latest"
    [ -n "${DATE}" ] && TARGET="${DATE}"
    [ "${LATEST}" = "true" ] && TARGET="latest"

    echo "==> Triggering restore.yml workflow (target=${TARGET})"
    echo "    S3 credentials will be read from GitHub Secrets"
    echo "    Project isolation: restricted to s3://rishi-yral/${PROJECT_REPO}/"
    echo ""

    if [ "${ASSUME_YES}" != "true" ]; then
        echo "WARNING: This will DROP the '${POSTGRES_DB}' database and replace"
        echo "it with the backup. All data created after the backup is lost."
        read -p "Type '${POSTGRES_DB}' to confirm: " CONFIRM
        [ "${CONFIRM}" = "${POSTGRES_DB}" ] || { echo "Aborted."; exit 1; }
    fi

    # Trigger the workflow
    gh workflow run restore.yml --repo "${ORG}/${PROJECT_REPO}" -f target="${TARGET}"
    echo "  Workflow triggered. Waiting for it to start..."

    # Find the run ID
    RID=""
    for i in 1 2 3 4 5 6; do
        sleep 5
        RID=$(gh run list --repo "${ORG}/${PROJECT_REPO}" --workflow=restore.yml --limit 1 \
                --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")
        [ -n "${RID}" ] && break
    done

    if [ -n "${RID}" ]; then
        echo "  Watching restore run ${RID}..."
        gh run watch "${RID}" --repo "${ORG}/${PROJECT_REPO}" --exit-status 2>&1 \
            && echo "✓ Restore completed successfully" \
            || { echo "✗ Restore failed. Check: gh run view ${RID} --repo ${ORG}/${PROJECT_REPO} --log-failed"; exit 1; }
    else
        echo "WARNING: Could not find restore run. Check GitHub Actions manually."
        exit 1
    fi

    echo ""
    echo "==> Verify:"
    echo "    curl https://${PROJECT_DOMAIN}/health"
    echo "    curl https://${PROJECT_DOMAIN}/"
    exit 0
fi

# =================================================================
# PATH 2: Restore from a local SQL file (--file)
# No S3 involved — upload file to server and restore directly
# =================================================================
echo "==> Restoring from local file: ${LOCAL_FILE}"
[ ! -f "${LOCAL_FILE}" ] && { echo "FATAL: file not found: ${LOCAL_FILE}"; exit 1; }

if [ "${ASSUME_YES}" != "true" ]; then
    echo ""
    echo "WARNING: This will DROP the '${POSTGRES_DB}' database and replace"
    echo "it with the contents of ${LOCAL_FILE}."
    read -p "Type '${POSTGRES_DB}' to confirm: " CONFIRM
    [ "${CONFIRM}" = "${POSTGRES_DB}" ] || { echo "Aborted."; exit 1; }
fi

# Upload the file to rishi-1
echo "==> Uploading ${LOCAL_FILE} to rishi-1..."
scp -i "${SSH_KEY}" "${LOCAL_FILE}" "${DEPLOY_USER}@${SERVER_1_IP}:/tmp/restore.sql.gz"

# Restore on the server
echo "==> Restoring..."
ssh -i "${SSH_KEY}" "${DEPLOY_USER}@${SERVER_1_IP}" bash <<REMOTE
set -e

C=\$(docker ps -qf "name=${SWARM_STACK}_patroni-rishi" | head -1)
[ -z "\$C" ] && { echo "FATAL: no local patroni container"; exit 1; }
PG=\$(docker exec "\$C" cat /run/secrets/postgres_password 2>/dev/null)
echo "using container \$C → haproxy-rishi-1 → leader"

docker exec -e PGPASSWORD="\$PG" "\$C" psql -h haproxy-rishi-1 -U postgres -c "
    SELECT pg_terminate_backend(pid) FROM pg_stat_activity
    WHERE datname = '${POSTGRES_DB}' AND pid <> pg_backend_pid();
" 2>/dev/null || true
docker exec -e PGPASSWORD="\$PG" "\$C" psql -h haproxy-rishi-1 -U postgres -c "DROP DATABASE IF EXISTS ${POSTGRES_DB};"
docker exec -e PGPASSWORD="\$PG" "\$C" psql -h haproxy-rishi-1 -U postgres -c "CREATE DATABASE ${POSTGRES_DB};"
echo "database recreated"

gunzip -c /tmp/restore.sql.gz | docker exec -i -e PGPASSWORD="\$PG" "\$C" psql -h haproxy-rishi-1 -U postgres -d ${POSTGRES_DB} 2>&1 | tail -5
echo "restore complete"

echo "--- tables after restore ---"
docker exec -e PGPASSWORD="\$PG" "\$C" psql -h haproxy-rishi-1 -U postgres -d ${POSTGRES_DB} -c "\\dt"

rm -f /tmp/restore.sql.gz
REMOTE

# Re-run migrations
echo "==> Re-running migrations..."
ssh -i "${SSH_KEY}" "${DEPLOY_USER}@${SERVER_1_IP}" \
    "cd /home/${DEPLOY_USER}/${PROJECT_REPO} && APP_DIR=/home/${DEPLOY_USER}/${PROJECT_REPO} bash scripts/ci/run-migrations.sh" 2>&1 || \
    echo "⚠ Migration runner failed — may need manual intervention"

# Restart app containers
echo "==> Restarting app containers..."
for IP in ${SERVER_1_IP} ${SERVER_2_IP}; do
    ssh -i "${SSH_KEY}" "${DEPLOY_USER}@${IP}" "docker restart ${PROJECT_REPO} 2>/dev/null" && \
        echo "  restarted on $(ssh -i "${SSH_KEY}" "${DEPLOY_USER}@${IP}" hostname)"
done

echo ""
echo "==> Restore complete. Verify:"
echo "    curl https://${PROJECT_DOMAIN}/health"
echo "    curl https://${PROJECT_DOMAIN}/"
