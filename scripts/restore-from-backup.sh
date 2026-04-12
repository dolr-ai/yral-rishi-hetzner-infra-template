#!/bin/bash
# =============================================================================
# restore-from-backup.sh — download a backup from S3 and restore it.
#
# Uses the backup Docker image (which has mc) for S3 access — no need to
# install aws-cli or mc on your Mac.
#
# Usage:
#   bash scripts/restore-from-backup.sh --latest
#   bash scripts/restore-from-backup.sh --date 2026-04-12
#   bash scripts/restore-from-backup.sh --file path/to/local.sql.gz
#   bash scripts/restore-from-backup.sh --latest --yes       # skip prompts
#
# After restore, the script:
#   1. Re-runs all pending migrations (the backup may be from before a migration)
#   2. Restarts app containers on both servers (clears stale connection pool)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

set -a
source "${REPO_ROOT}/project.config"
source "${REPO_ROOT}/servers.config"
set +a

SSH_KEY="${SSH_KEY_PATH/#\~/$HOME}"

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

# S3 credentials — try env vars first, fall back to macOS Keychain
S3_ACCESS="${BACKUP_S3_ACCESS_KEY:-${AWS_ACCESS_KEY_ID:-}}"
S3_SECRET="${BACKUP_S3_SECRET_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
# If not set via env vars, read from macOS Keychain (where new-service.sh stores them)
if [ -z "${S3_ACCESS}" ] && command -v security &>/dev/null; then
    S3_ACCESS=$(security find-generic-password -a "dolr-ai" -s "BACKUP_S3_ACCESS_KEY" -w 2>/dev/null || echo "")
fi
if [ -z "${S3_SECRET}" ] && command -v security &>/dev/null; then
    S3_SECRET=$(security find-generic-password -a "dolr-ai" -s "BACKUP_S3_SECRET_KEY" -w 2>/dev/null || echo "")
fi

BACKUP_IMAGE="${IMAGE_REPO}-backup:latest"
S3_PREFIX="rishi-yral/${PROJECT_REPO}"
DOWNLOAD_PATH="/tmp/restore_${PROJECT_REPO}.sql.gz"

# ----- PROJECT ISOLATION GUARD -----
# Ensure we only restore from THIS project's S3 prefix, never another project's.
if [ -z "${PROJECT_REPO}" ] || [ "${PROJECT_REPO}" = "yral-" ]; then
    echo "FATAL: PROJECT_REPO is empty or invalid — refusing to run"
    exit 1
fi
echo "==> Project isolation: restore restricted to s3://${S3_PREFIX}/"

# ----- Download the backup -----
if [ -n "${LOCAL_FILE}" ]; then
    [ ! -f "${LOCAL_FILE}" ] && { echo "FATAL: file not found: ${LOCAL_FILE}"; exit 1; }
    DOWNLOAD_PATH="${LOCAL_FILE}"
    echo "==> Using local file: ${DOWNLOAD_PATH}"
elif [ -z "${S3_ACCESS}" ] || [ -z "${S3_SECRET}" ]; then
    echo "FATAL: S3 credentials not set."
    echo "  Export BACKUP_S3_ACCESS_KEY + BACKUP_S3_SECRET_KEY"
    exit 1
else
    echo "==> Finding backup in S3..."

    # Use the backup Docker image (has mc) via SSH to rishi-1
    BACKUP_FILE=""
    if [ "${LATEST}" = "true" ]; then
        BACKUP_FILE=$(ssh -i "${SSH_KEY}" "${DEPLOY_USER}@${SERVER_1_IP}" "
            docker run --rm ${BACKUP_IMAGE} sh -c '
                mc alias set h ${BACKUP_S3_ENDPOINT} ${S3_ACCESS} ${S3_SECRET} --api s3v4 >/dev/null 2>&1
                mc ls h/${S3_PREFIX}/daily/ | awk \"{print \\\$NF}\" | sort | tail -1
            '
        ")
    elif [ -n "${DATE}" ]; then
        BACKUP_FILE=$(ssh -i "${SSH_KEY}" "${DEPLOY_USER}@${SERVER_1_IP}" "
            docker run --rm ${BACKUP_IMAGE} sh -c '
                mc alias set h ${BACKUP_S3_ENDPOINT} ${S3_ACCESS} ${S3_SECRET} --api s3v4 >/dev/null 2>&1
                mc ls h/${S3_PREFIX}/daily/ | awk \"{print \\\$NF}\" | grep \"^${DATE}\" | sort | tail -1
            '
        ")
    fi

    [ -z "${BACKUP_FILE}" ] && { echo "FATAL: no backup found"; exit 1; }
    echo "    found: ${BACKUP_FILE}"

    # Download to rishi-1's /tmp
    echo "==> Downloading ${BACKUP_FILE} to rishi-1..."
    ssh -i "${SSH_KEY}" "${DEPLOY_USER}@${SERVER_1_IP}" "
        docker run --rm -v /tmp:/download ${BACKUP_IMAGE} sh -c '
            mc alias set h ${BACKUP_S3_ENDPOINT} ${S3_ACCESS} ${S3_SECRET} --api s3v4 >/dev/null 2>&1
            mc cp h/${S3_PREFIX}/daily/${BACKUP_FILE} /download/restore.sql.gz
        '
    "
    DOWNLOAD_PATH="/tmp/restore.sql.gz"
fi

# ----- Confirmation -----
echo
echo "=========================================="
echo " RESTORE: ${POSTGRES_DB}"
echo " from:    ${BACKUP_FILE:-${LOCAL_FILE}}"
echo " server:  ${SERVER_1_IP}"
echo
echo " WARNING: this will DROP the existing database,"
echo " restore from the backup, then re-run any pending"
echo " migrations to bring the schema up to date."
echo "=========================================="

if [ "${ASSUME_YES}" != "true" ]; then
    read -p "Type '${POSTGRES_DB}' to confirm: " CONFIRM
    [ "${CONFIRM}" = "${POSTGRES_DB}" ] || { echo "Aborted."; exit 1; }
fi

# ----- Restore -----
echo "==> Restoring..."
ssh -i "${SSH_KEY}" "${DEPLOY_USER}@${SERVER_1_IP}" bash <<REMOTE
set -e

# Find ANY local patroni container (connect through HAProxy to the leader)
C=\$(docker ps -qf "name=${SWARM_STACK}_patroni-rishi" | head -1)
[ -z "\$C" ] && { echo "FATAL: no local patroni container"; exit 1; }
PG=\$(docker exec "\$C" cat /run/secrets/postgres_password 2>/dev/null)
echo "using container \$C → haproxy-rishi-1 → leader"

# Terminate connections + drop + recreate (via HAProxy → leader)
docker exec -e PGPASSWORD="\$PG" "\$C" psql -h haproxy-rishi-1 -U postgres -c "
    SELECT pg_terminate_backend(pid) FROM pg_stat_activity
    WHERE datname = '${POSTGRES_DB}' AND pid <> pg_backend_pid();
" 2>/dev/null || true
docker exec -e PGPASSWORD="\$PG" "\$C" psql -h haproxy-rishi-1 -U postgres -c "DROP DATABASE IF EXISTS ${POSTGRES_DB};"
docker exec -e PGPASSWORD="\$PG" "\$C" psql -h haproxy-rishi-1 -U postgres -c "CREATE DATABASE ${POSTGRES_DB};"
echo "database recreated"

# Restore from dump (via HAProxy → leader)
gunzip -c ${DOWNLOAD_PATH} | docker exec -i -e PGPASSWORD="\$PG" "\$C" psql -h haproxy-rishi-1 -U postgres -d ${POSTGRES_DB} 2>&1 | tail -5
echo "restore complete"

# Verify
echo "--- tables after restore ---"
docker exec -e PGPASSWORD="\$PG" "\$C" psql -h haproxy-rishi-1 -U postgres -d ${POSTGRES_DB} -c "\\dt"
echo "--- schema_migrations ---"
docker exec -e PGPASSWORD="\$PG" "\$C" psql -h haproxy-rishi-1 -U postgres -d ${POSTGRES_DB} -c "SELECT * FROM schema_migrations ORDER BY filename;" 2>/dev/null || echo "(no schema_migrations table)"
REMOTE

# ----- Re-run migrations (backup may be from before a migration) -----
echo "==> Re-running migrations to bring schema up to date..."
ssh -i "${SSH_KEY}" "${DEPLOY_USER}@${SERVER_1_IP}" \
    "cd /home/${DEPLOY_USER}/${PROJECT_REPO} && APP_DIR=/home/${DEPLOY_USER}/${PROJECT_REPO} bash scripts/ci/run-migrations.sh" 2>&1 || \
    echo "⚠ Migration runner failed — may need manual intervention"

# ----- Restart app containers -----
echo "==> Restarting app containers (clearing stale connection pool)..."
for IP in ${SERVER_1_IP} ${SERVER_2_IP}; do
    ssh -i "${SSH_KEY}" "${DEPLOY_USER}@${IP}" "docker restart ${PROJECT_REPO} 2>/dev/null" && \
        echo "  restarted on $(ssh -i "${SSH_KEY}" "${DEPLOY_USER}@${IP}" hostname)"
done

sleep 5
echo
echo "==> Restore complete. Verify:"
echo "    curl https://${PROJECT_DOMAIN}/"
echo "    curl https://${PROJECT_DOMAIN}/health"
