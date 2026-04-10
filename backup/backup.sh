#!/bin/bash
# =============================================================================
# Daily pg_dump backup to S3-compatible object storage (Hetzner, R2, B2, AWS).
#
# Run by cron inside the backup container (backup/stack.yml), or manually:
#   bash backup/backup.sh
#
# What it does:
#   1. pg_dump the project's database via HAProxy (connects to the leader)
#   2. Compress with gzip (~10x reduction for SQL dumps)
#   3. Upload to s3://<BUCKET>/<PROJECT_REPO>/daily/YYYY-MM-DD_HHMMSS.sql.gz
#   4. Prune old backups beyond retention window
#   5. Verify the upload succeeded by checking the object exists
#
# Required env vars:
#   POSTGRES_DB             — from project.config
#   PROJECT_REPO            — from project.config
#   BACKUP_S3_ENDPOINT      — from project.config
#   BACKUP_S3_BUCKET        — from project.config
#   BACKUP_RETENTION_DAILY  — from project.config (default: 7)
#   BACKUP_RETENTION_WEEKLY — from project.config (default: 4)
#   AWS_ACCESS_KEY_ID       — from GitHub Secret BACKUP_S3_ACCESS_KEY
#   AWS_SECRET_ACCESS_KEY   — from GitHub Secret BACKUP_S3_SECRET_KEY
#   PGPASSWORD              — postgres password (from Swarm secret)
#   PGHOST                  — HAProxy host (default: haproxy-rishi-1)
#   PGPORT                  — HAProxy port (default: 5432)
#   PGUSER                  — postgres user (default: postgres)
# =============================================================================

set -euo pipefail

PGHOST="${PGHOST:-haproxy-rishi-1}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
RETENTION_DAILY="${BACKUP_RETENTION_DAILY:-7}"
RETENTION_WEEKLY="${BACKUP_RETENTION_WEEKLY:-4}"

TIMESTAMP=$(date -u +%H%M%S)
DATE_ONLY=$(date -u +%Y-%m-%d)
DAY_OF_WEEK=$(date -u +%u)  # 1=Monday, 7=Sunday
DUMP_FILE="/tmp/${PROJECT_REPO}_${DATE_ONLY}_${TIMESTAMP}.sql.gz"
S3_PREFIX="s3://${BACKUP_S3_BUCKET}/${PROJECT_REPO}"

# Hetzner Object Storage uses path-style addressing (bucket in the URL path,
# not in the hostname). Set this so aws-cli doesn't try virtual-hosted style.
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-hel1}"

log() { echo "[backup] $(date -u +%H:%M:%S) $*"; }

# ----- Validate -----
for VAR in POSTGRES_DB PROJECT_REPO BACKUP_S3_ENDPOINT BACKUP_S3_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY PGPASSWORD; do
    if [ -z "${!VAR:-}" ]; then
        log "FATAL: ${VAR} not set"
        exit 1
    fi
done

# ----- 1. pg_dump -----
log "dumping ${POSTGRES_DB} from ${PGHOST}:${PGPORT}..."
pg_dump -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${POSTGRES_DB}" \
    --no-owner --no-privileges --clean --if-exists \
    | gzip -9 > "${DUMP_FILE}"

DUMP_SIZE=$(stat -c%s "${DUMP_FILE}" 2>/dev/null || stat -f%z "${DUMP_FILE}" 2>/dev/null)
if [ "${DUMP_SIZE}" -lt 100 ]; then
    log "FATAL: dump file is ${DUMP_SIZE} bytes — too small, likely empty or failed"
    rm -f "${DUMP_FILE}"
    exit 1
fi
log "dump complete: ${DUMP_SIZE} bytes (compressed)"

# ----- 2. Upload to daily/ -----
S3_DAILY_KEY="${S3_PREFIX}/daily/${DATE_ONLY}_${TIMESTAMP}.sql.gz"
# e.g. s3://rishi-yral/yral-my-service/daily/2026-04-10_030000.sql.gz
log "uploading to ${S3_DAILY_KEY}..."
aws s3 cp "${DUMP_FILE}" "${S3_DAILY_KEY}" \
    --endpoint-url "${BACKUP_S3_ENDPOINT}" \
    --no-progress

# ----- 3. Copy to weekly/ on Sundays -----
if [ "${DAY_OF_WEEK}" = "7" ]; then
    S3_WEEKLY_KEY="${S3_PREFIX}/weekly/${DATE_ONLY}.sql.gz"
    log "Sunday — copying to weekly: ${S3_WEEKLY_KEY}"
    aws s3 cp "${DUMP_FILE}" "${S3_WEEKLY_KEY}" \
        --endpoint-url "${BACKUP_S3_ENDPOINT}" \
        --no-progress
fi

rm -f "${DUMP_FILE}"

# ----- 4. Prune old daily backups -----
log "pruning daily backups older than ${RETENTION_DAILY} days..."
aws s3 ls "${S3_PREFIX}/daily/" --endpoint-url "${BACKUP_S3_ENDPOINT}" 2>/dev/null \
    | awk '{print $NF}' \
    | sort \
    | head -n -"${RETENTION_DAILY}" \
    | while read -r OLD_FILE; do
        [ -z "${OLD_FILE}" ] && continue
        log "  deleting daily/${OLD_FILE}"
        aws s3 rm "${S3_PREFIX}/daily/${OLD_FILE}" \
            --endpoint-url "${BACKUP_S3_ENDPOINT}" --quiet
    done

# Prune old weekly backups
log "pruning weekly backups older than ${RETENTION_WEEKLY} weeks..."
aws s3 ls "${S3_PREFIX}/weekly/" --endpoint-url "${BACKUP_S3_ENDPOINT}" 2>/dev/null \
    | awk '{print $NF}' \
    | sort \
    | head -n -"${RETENTION_WEEKLY}" \
    | while read -r OLD_FILE; do
        [ -z "${OLD_FILE}" ] && continue
        log "  deleting weekly/${OLD_FILE}"
        aws s3 rm "${S3_PREFIX}/weekly/${OLD_FILE}" \
            --endpoint-url "${BACKUP_S3_ENDPOINT}" --quiet
    done

# ----- 5. Verify -----
VERIFY=$(aws s3 ls "${S3_DAILY_KEY}" --endpoint-url "${BACKUP_S3_ENDPOINT}" 2>/dev/null | wc -l | tr -d ' ')
if [ "${VERIFY}" -ge 1 ]; then
    log "✓ backup verified: ${S3_DAILY_KEY}"
else
    log "✗ VERIFICATION FAILED — backup may not have uploaded"
    exit 1
fi

log "done."
