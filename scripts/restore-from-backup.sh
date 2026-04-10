#!/bin/bash
# =============================================================================
# restore-from-backup.sh — download a pg_dump from S3 and restore it.
#
# Usage:
#   bash scripts/restore-from-backup.sh --date 2026-04-09
#   bash scripts/restore-from-backup.sh --latest
#   bash scripts/restore-from-backup.sh --latest --yes       # skip prompts
#   bash scripts/restore-from-backup.sh --file path/to/local.sql.gz
#
# What it does:
#   1. Downloads the specified backup from S3 (or uses a local file)
#   2. Connects to the Patroni leader via SSH + HAProxy
#   3. Drops and recreates the project database
#   4. Restores the dump via psql
#   5. Verifies the restore by counting rows in key tables
#
# PREREQUISITES:
#   - SSH access to the servers (uses servers.config)
#   - AWS CLI on your Mac: brew install awscli
#   - BACKUP_S3_ACCESS_KEY + BACKUP_S3_SECRET_KEY exported (or set in env)
#
# SECURITY: credentials are NEVER written to disk. They're read from env
# vars and passed to `aws` which uses them in-memory only.
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
        --date)  DATE="$2"; shift 2 ;;
        --latest) LATEST="true"; shift ;;
        --file)  LOCAL_FILE="$2"; shift 2 ;;
        --yes)   ASSUME_YES="true"; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# Validate S3 creds
if [ -z "${LOCAL_FILE}" ]; then
    for VAR in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
        # Try reading from BACKUP_S3_* env vars (which is how GitHub Secrets name them)
        [ -z "${!VAR:-}" ] && eval "export ${VAR}=\${BACKUP_S3_ACCESS_KEY:-}" 2>/dev/null
    done
    [ -z "${AWS_ACCESS_KEY_ID:-}" ] && export AWS_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY:-}"
    [ -z "${AWS_SECRET_ACCESS_KEY:-}" ] && export AWS_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_KEY:-}"
    if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
        echo "FATAL: S3 credentials not set. Export BACKUP_S3_ACCESS_KEY + BACKUP_S3_SECRET_KEY"
        exit 1
    fi
fi

S3_PREFIX="s3://${BACKUP_S3_BUCKET}/${PROJECT_REPO}"
RESTORE_FILE=""

if [ -n "${LOCAL_FILE}" ]; then
    [ ! -f "${LOCAL_FILE}" ] && { echo "FATAL: file not found: ${LOCAL_FILE}"; exit 1; }
    RESTORE_FILE="${LOCAL_FILE}"
    echo "==> Restoring from local file: ${RESTORE_FILE}"
elif [ "${LATEST}" = "true" ]; then
    echo "==> Finding latest backup in ${S3_PREFIX}/daily/..."
    LATEST_KEY=$(aws s3 ls "${S3_PREFIX}/daily/" --endpoint-url "${BACKUP_S3_ENDPOINT}" 2>/dev/null \
        | awk '{print $NF}' | sort | tail -1)
    [ -z "${LATEST_KEY}" ] && { echo "FATAL: no backups found in ${S3_PREFIX}/daily/"; exit 1; }
    echo "    latest: ${LATEST_KEY}"
    RESTORE_FILE="/tmp/${LATEST_KEY}"
    aws s3 cp "${S3_PREFIX}/daily/${LATEST_KEY}" "${RESTORE_FILE}" \
        --endpoint-url "${BACKUP_S3_ENDPOINT}"
elif [ -n "${DATE}" ]; then
    echo "==> Finding backup for date ${DATE}..."
    MATCH=$(aws s3 ls "${S3_PREFIX}/daily/" --endpoint-url "${BACKUP_S3_ENDPOINT}" 2>/dev/null \
        | awk '{print $NF}' | grep "^${DATE}" | sort | tail -1)
    [ -z "${MATCH}" ] && { echo "FATAL: no backup found for date ${DATE}"; exit 1; }
    echo "    found: ${MATCH}"
    RESTORE_FILE="/tmp/${MATCH}"
    aws s3 cp "${S3_PREFIX}/daily/${MATCH}" "${RESTORE_FILE}" \
        --endpoint-url "${BACKUP_S3_ENDPOINT}"
else
    echo "Usage: bash scripts/restore-from-backup.sh --latest | --date YYYY-MM-DD | --file path"
    exit 1
fi

# Show what we're about to do
DUMP_SIZE=$(stat -c%s "${RESTORE_FILE}" 2>/dev/null || stat -f%z "${RESTORE_FILE}" 2>/dev/null)
echo
echo "=========================================="
echo " RESTORE PLAN"
echo "  database:  ${POSTGRES_DB}"
echo "  from:      ${RESTORE_FILE} ($(( DUMP_SIZE / 1024 )) KB)"
echo "  server:    ${SERVER_1_IP} (via HAProxy)"
echo
echo "  WARNING: this will DROP the existing database and"
echo "  replace it with the backup contents."
echo "=========================================="

if [ "${ASSUME_YES}" != "true" ]; then
    read -p "Type '${POSTGRES_DB}' to confirm: " CONFIRM
    [ "${CONFIRM}" = "${POSTGRES_DB}" ] || { echo "Aborted."; exit 1; }
fi

# Find the Patroni leader and restore via psql
echo "==> Restoring..."
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${DEPLOY_USER}@${SERVER_1_IP}" bash <<REMOTE
set -e
# Find the leader container
for C in \$(docker ps -qf name=${SWARM_STACK}_patroni-rishi); do
    IS_LEADER=\$(docker exec "\$C" psql -h 127.0.0.1 -U postgres -tAc "SELECT pg_is_in_recovery();" 2>/dev/null)
    if [ "\$IS_LEADER" = "f" ]; then
        LEADER="\$C"
        break
    fi
done
[ -z "\${LEADER:-}" ] && { echo "FATAL: no leader found"; exit 1; }
echo "leader: \$LEADER"

# Drop + recreate the database
docker exec "\$LEADER" psql -h 127.0.0.1 -U postgres -c "
    SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${POSTGRES_DB}' AND pid <> pg_backend_pid();
" 2>/dev/null || true
docker exec "\$LEADER" psql -h 127.0.0.1 -U postgres -c "DROP DATABASE IF EXISTS ${POSTGRES_DB};"
docker exec "\$LEADER" psql -h 127.0.0.1 -U postgres -c "CREATE DATABASE ${POSTGRES_DB};"
echo "database recreated"
REMOTE

# Upload the dump to the server, decompress, and restore via psql
echo "==> Uploading dump to server..."
scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${RESTORE_FILE}" \
    "${DEPLOY_USER}@${SERVER_1_IP}:/tmp/restore_dump.sql.gz"

ssh -i "${SSH_KEY}" "${DEPLOY_USER}@${SERVER_1_IP}" bash <<REMOTE
set -e
LEADER=""
for C in \$(docker ps -qf name=${SWARM_STACK}_patroni-rishi); do
    IS_LEADER=\$(docker exec "\$C" psql -h 127.0.0.1 -U postgres -tAc "SELECT pg_is_in_recovery();" 2>/dev/null)
    [ "\$IS_LEADER" = "f" ] && { LEADER="\$C"; break; }
done

echo "restoring to \$LEADER..."
gunzip -c /tmp/restore_dump.sql.gz | docker exec -i "\$LEADER" psql -h 127.0.0.1 -U postgres -d ${POSTGRES_DB} 2>&1 | tail -5
rm -f /tmp/restore_dump.sql.gz

echo "==> Verifying restore..."
docker exec "\$LEADER" psql -h 127.0.0.1 -U postgres -d ${POSTGRES_DB} -c "\\dt" 2>/dev/null
docker exec "\$LEADER" psql -h 127.0.0.1 -U postgres -d ${POSTGRES_DB} -c "SELECT count(*) AS rows FROM counter;" 2>/dev/null || true
REMOTE

# Clean up local temp file (unless it was a user-provided --file)
if [ -z "${LOCAL_FILE}" ] && [ -f "${RESTORE_FILE}" ]; then
    rm -f "${RESTORE_FILE}"
fi

echo
echo "==> Restore complete. Test the app:"
echo "    curl https://${PROJECT_DOMAIN}/"
