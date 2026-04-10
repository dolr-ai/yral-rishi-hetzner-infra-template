#!/bin/bash
# =============================================================================
# Daily pg_dump backup to S3-compatible object storage via MinIO Client (mc).
#
# Uses mc instead of aws-cli because aws-cli v2 on Alpine crashes with
# Hetzner Object Storage's error response handling. mc is a single static
# binary that works reliably with any S3-compatible service.
#
# Run by the scheduled GitHub Actions workflow (backup.yml), or manually:
#   docker run --rm --network <overlay> -e ... <backup-image>
#
# Required env vars:
#   POSTGRES_DB, PROJECT_REPO, PGHOST, PGPORT, PGUSER, PGPASSWORD
#   BACKUP_S3_ENDPOINT, BACKUP_S3_BUCKET
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
#   BACKUP_RETENTION_DAILY (default: 7), BACKUP_RETENTION_WEEKLY (default: 4)
# =============================================================================

set -euo pipefail

PGHOST="${PGHOST:-haproxy-rishi-1}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
RETENTION_DAILY="${BACKUP_RETENTION_DAILY:-7}"
RETENTION_WEEKLY="${BACKUP_RETENTION_WEEKLY:-4}"

DATE_ONLY=$(date -u +%Y-%m-%d)
TIMESTAMP=$(date -u +%H%M%S)
DAY_OF_WEEK=$(date -u +%u)
DUMP_FILE="/tmp/${PROJECT_REPO}_${DATE_ONLY}_${TIMESTAMP}.sql.gz"
MC_ALIAS="hetzner"
S3_PREFIX="${MC_ALIAS}/${BACKUP_S3_BUCKET}/${PROJECT_REPO}"

log() { echo "[backup] $(date -u +%H:%M:%S) $*"; }

# ----- Validate -----
for VAR in POSTGRES_DB PROJECT_REPO BACKUP_S3_ENDPOINT BACKUP_S3_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY PGPASSWORD; do
    if [ -z "${!VAR:-}" ]; then
        log "FATAL: ${VAR} not set"
        exit 1
    fi
done

# ----- Configure mc -----
log "configuring mc alias '${MC_ALIAS}' → ${BACKUP_S3_ENDPOINT}"
mc alias set "${MC_ALIAS}" "${BACKUP_S3_ENDPOINT}" \
    "${AWS_ACCESS_KEY_ID}" "${AWS_SECRET_ACCESS_KEY}" \
    --api s3v4 >/dev/null 2>&1

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
DAILY_KEY="${S3_PREFIX}/daily/${DATE_ONLY}_${TIMESTAMP}.sql.gz"
log "uploading to ${DAILY_KEY}..."
mc cp "${DUMP_FILE}" "${DAILY_KEY}"

# ----- 3. Copy to weekly/ on Sundays -----
if [ "${DAY_OF_WEEK}" = "7" ]; then
    WEEKLY_KEY="${S3_PREFIX}/weekly/${DATE_ONLY}.sql.gz"
    log "Sunday — copying to weekly: ${WEEKLY_KEY}"
    mc cp "${DUMP_FILE}" "${WEEKLY_KEY}"
fi

rm -f "${DUMP_FILE}"

# ----- 4. Prune old daily backups -----
log "pruning daily backups older than ${RETENTION_DAILY} days..."
mc ls "${S3_PREFIX}/daily/" 2>/dev/null | awk '{print $NF}' | sort | head -n -"${RETENTION_DAILY}" | while read -r OLD; do
    [ -z "${OLD}" ] && continue
    log "  deleting daily/${OLD}"
    mc rm "${S3_PREFIX}/daily/${OLD}" 2>/dev/null || true
done

# Prune old weekly backups
log "pruning weekly backups older than ${RETENTION_WEEKLY} weeks..."
mc ls "${S3_PREFIX}/weekly/" 2>/dev/null | awk '{print $NF}' | sort | head -n -"${RETENTION_WEEKLY}" | while read -r OLD; do
    [ -z "${OLD}" ] && continue
    log "  deleting weekly/${OLD}"
    mc rm "${S3_PREFIX}/weekly/${OLD}" 2>/dev/null || true
done

# ----- 5. Verify -----
if mc stat "${DAILY_KEY}" >/dev/null 2>&1; then
    log "✓ backup verified: ${DAILY_KEY}"
else
    log "✗ VERIFICATION FAILED — backup may not have uploaded"
    exit 1
fi

log "done."
