#!/bin/bash
# ---------------------------------------------------------------------------
# backup.sh — exports the database and uploads it to Hetzner Object Storage.
#
# WHAT THIS SCRIPT DOES (5 steps):
#   1. pg_dump: exports the ENTIRE database to a SQL text file
#   2. gzip: compresses the file (~10x smaller)
#   3. Upload: sends the compressed file to S3 (Hetzner Object Storage)
#   4. Prune: deletes old backups beyond the retention window
#   5. Verify: confirms the upload succeeded
#
# WHERE DO BACKUPS GO?
#   s3://rishi-yral/<PROJECT_REPO>/daily/2026-04-12_030000.sql.gz
#   Each service has its own folder (PROJECT_REPO) — zero overlap.
#
# WHAT IS pg_dump?
#   A PostgreSQL tool that exports the entire database (tables, data, indexes)
#   as a SQL text file. You can restore from it with: psql < dump.sql
#
# WHAT IS MinIO Client (mc)?
#   A command-line tool for uploading/downloading files to S3-compatible
#   storage (Hetzner, AWS, Cloudflare R2, etc.). Similar to "aws s3 cp"
#   but more reliable with Hetzner's S3 implementation.
#
# WHEN DOES THIS RUN?
#   Daily at 3:00 AM UTC via GitHub Actions (backup.yml workflow).
#   Can also be triggered manually: gh workflow run backup.yml
#
# REQUIRED ENVIRONMENT VARIABLES:
#   POSTGRES_DB           — database name to back up
#   PROJECT_REPO          — used as the S3 folder name
#   PGHOST                — database host (default: haproxy-rishi-1)
#   PGPORT                — database port (default: 5432)
#   PGUSER                — database user (default: postgres)
#   PGPASSWORD            — database password
#   BACKUP_S3_ENDPOINT    — S3 endpoint URL (e.g., https://hel1.your-objectstorage.com)
#   BACKUP_S3_BUCKET      — S3 bucket name (e.g., rishi-yral)
#   AWS_ACCESS_KEY_ID     — S3 access key
#   AWS_SECRET_ACCESS_KEY — S3 secret key
#   BACKUP_RETENTION_DAILY  — how many daily backups to keep (default: 7)
#   BACKUP_RETENTION_WEEKLY — how many weekly backups to keep (default: 4)
# ---------------------------------------------------------------------------

# "set -euo pipefail" = strict error handling:
#   -e: stop on any error
#   -u: treat unset variables as errors (catch typos)
#   -o pipefail: if any command in a pipe fails, the whole pipe fails
set -euo pipefail

# Set defaults for optional variables.
# "${VAR:-default}" means "use VAR if set, otherwise use default"
PGHOST="${PGHOST:-haproxy-rishi-1}"    # connect to HAProxy (routes to DB leader)
PGPORT="${PGPORT:-5432}"                # PostgreSQL's standard port
PGUSER="${PGUSER:-postgres}"            # the database superuser
RETENTION_DAILY="${BACKUP_RETENTION_DAILY:-7}"    # keep 7 daily backups
RETENTION_WEEKLY="${BACKUP_RETENTION_WEEKLY:-4}"  # keep 4 weekly backups

# Generate timestamps for the backup filename
# "date -u" = UTC time (same timezone everywhere, avoids confusion)
# "+%Y-%m-%d" = format: 2026-04-12
# "+%H%M%S" = format: 030000 (3:00:00 AM)
# "+%u" = day of week: 1=Monday, 7=Sunday
DATE_ONLY=$(date -u +%Y-%m-%d)
TIMESTAMP=$(date -u +%H%M%S)
DAY_OF_WEEK=$(date -u +%u)

# The temporary file where pg_dump writes the compressed backup
DUMP_FILE="/tmp/${PROJECT_REPO}_${DATE_ONLY}_${TIMESTAMP}.sql.gz"

# MC_ALIAS: a name for the S3 connection in MinIO Client's config
# (like a bookmark — "hetzner" maps to the endpoint + credentials)
MC_ALIAS="hetzner"

# S3_PREFIX: the folder path in the bucket where this service's backups go
# Example: hetzner/rishi-yral/yral-my-service
S3_PREFIX="${MC_ALIAS}/${BACKUP_S3_BUCKET}/${PROJECT_REPO}"

# A helper function for consistent log output
# "log() { ... }" defines a function. "$*" means "all arguments."
log() { echo "[backup] $(date -u +%H:%M:%S) $*"; }

# ----- VALIDATE: make sure all required env vars are set -----
# Loop through each required variable name
for VAR in POSTGRES_DB PROJECT_REPO BACKUP_S3_ENDPOINT BACKUP_S3_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY PGPASSWORD; do
    # "${!VAR:-}" is "indirect expansion" — it reads the VALUE of the
    # variable whose NAME is in $VAR. If the value is empty, fail.
    if [ -z "${!VAR:-}" ]; then
        log "FATAL: ${VAR} not set"
        exit 1
    fi
done

# ----- CONFIGURE MinIO Client -----
# "mc alias set" saves the S3 connection details under the name "hetzner"
# --api s3v4 = use S3 signature version 4 (required by Hetzner)
# ">/dev/null 2>&1" = suppress all output (success or error messages)
log "configuring mc alias '${MC_ALIAS}' → ${BACKUP_S3_ENDPOINT}"
mc alias set "${MC_ALIAS}" "${BACKUP_S3_ENDPOINT}" \
    "${AWS_ACCESS_KEY_ID}" "${AWS_SECRET_ACCESS_KEY}" \
    --api s3v4 >/dev/null 2>&1

# ----- STEP 1: pg_dump (export the database) -----
# pg_dump connects to PostgreSQL and exports everything as SQL statements.
# Options:
#   -h: host (HAProxy → routes to the leader)
#   -p: port
#   -U: username
#   -d: database name
#   --no-owner: don't include ownership commands (avoids permission issues on restore)
#   --no-privileges: don't include GRANT/REVOKE commands
#   --clean: add DROP TABLE before CREATE TABLE (so restore replaces existing tables)
#   --if-exists: don't error if tables don't exist when dropping
#
# The "|" (pipe) sends pg_dump's output to gzip, which compresses it.
# "gzip -9" = maximum compression (smallest file, slower compression)
# "> ${DUMP_FILE}" = write the compressed output to a file
log "dumping ${POSTGRES_DB} from ${PGHOST}:${PGPORT}..."
pg_dump -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${POSTGRES_DB}" \
    --no-owner --no-privileges --clean --if-exists \
    | gzip -9 > "${DUMP_FILE}"

# Check the file size to make sure the dump isn't empty
# "stat -c%s" (Linux) or "stat -f%z" (macOS) gets the file size in bytes
DUMP_SIZE=$(stat -c%s "${DUMP_FILE}" 2>/dev/null || stat -f%z "${DUMP_FILE}" 2>/dev/null)
if [ "${DUMP_SIZE}" -lt 100 ]; then
    # A valid dump is always > 100 bytes. If smaller, something went wrong
    # (empty database, connection error that produced a 0-byte file, etc.)
    log "FATAL: dump file is ${DUMP_SIZE} bytes — too small, likely empty or failed"
    rm -f "${DUMP_FILE}"
    exit 1
fi
log "dump complete: ${DUMP_SIZE} bytes (compressed)"

# ----- STEP 2: Upload to the daily/ folder -----
# "mc cp" copies a local file to S3 (like "cp" but for cloud storage)
DAILY_KEY="${S3_PREFIX}/daily/${DATE_ONLY}_${TIMESTAMP}.sql.gz"
log "uploading to ${DAILY_KEY}..."
mc cp "${DUMP_FILE}" "${DAILY_KEY}"

# ----- STEP 3: Copy to weekly/ on Sundays -----
# On Sundays (day 7), also save a copy in the weekly/ folder.
# Weekly backups are kept longer (4 weeks vs 7 days) for deeper history.
if [ "${DAY_OF_WEEK}" = "7" ]; then
    WEEKLY_KEY="${S3_PREFIX}/weekly/${DATE_ONLY}.sql.gz"
    log "Sunday — copying to weekly: ${WEEKLY_KEY}"
    mc cp "${DUMP_FILE}" "${WEEKLY_KEY}"
fi

# Delete the local temp file (we've uploaded it to S3)
rm -f "${DUMP_FILE}"

# ----- STEP 4: Prune old backups -----
# Delete daily backups beyond the retention window.
# "mc ls" lists files in S3 (like "ls" for cloud storage)
# "awk '{print $NF}'" extracts the filename (last field)
# "sort" orders alphabetically (oldest first, because filenames have dates)
# "head -n -7" shows all lines EXCEPT the last 7 (keeps the 7 newest)
# "while read OLD" loops through each old file and deletes it
log "pruning daily backups older than ${RETENTION_DAILY} days..."
mc ls "${S3_PREFIX}/daily/" 2>/dev/null | awk '{print $NF}' | sort | head -n -"${RETENTION_DAILY}" | while read -r OLD; do
    [ -z "${OLD}" ] && continue    # skip empty lines
    log "  deleting daily/${OLD}"
    mc rm "${S3_PREFIX}/daily/${OLD}" 2>/dev/null || true  # don't fail if already deleted
done

# Same pruning for weekly backups
log "pruning weekly backups older than ${RETENTION_WEEKLY} weeks..."
mc ls "${S3_PREFIX}/weekly/" 2>/dev/null | awk '{print $NF}' | sort | head -n -"${RETENTION_WEEKLY}" | while read -r OLD; do
    [ -z "${OLD}" ] && continue
    log "  deleting weekly/${OLD}"
    mc rm "${S3_PREFIX}/weekly/${OLD}" 2>/dev/null || true
done

# ----- STEP 5: Verify the upload -----
# "mc stat" checks if the file exists in S3 (like "ls" for one file)
# If it exists → backup succeeded. If not → something went wrong.
if mc stat "${DAILY_KEY}" >/dev/null 2>&1; then
    log "✓ backup verified: ${DAILY_KEY}"
else
    log "✗ VERIFICATION FAILED — backup may not have uploaded"
    exit 1
fi

log "done."
