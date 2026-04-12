# ---------------------------------------------------------------------------
# backup/Dockerfile — builds a lightweight container for database backups.
#
# WHAT DOES THIS CONTAINER DO?
# It runs pg_dump (PostgreSQL's backup tool) to export the entire database
# to a compressed file, then uploads it to Hetzner Object Storage (S3)
# using MinIO Client (mc).
#
# WHY A SEPARATE CONTAINER?
# The app container doesn't have pg_dump or mc installed (it only has
# Python + FastAPI). Rather than bloating the app image with backup tools,
# we keep a small, focused backup image.
#
# WHY MINIO CLIENT (mc) INSTEAD OF AWS CLI?
# aws-cli v2 on Alpine Linux crashes with Hetzner Object Storage's error
# responses (a bug in aws-cli's Python error handler). mc is a single
# static binary that works reliably with ANY S3-compatible service.
#
# WHEN DOES IT RUN?
# Daily at 3:00 AM UTC via the GitHub Actions workflow (backup.yml).
# Can also be triggered manually: gh workflow run backup.yml
# ---------------------------------------------------------------------------

# Start from Alpine Linux 3.20 — a minimal Linux distribution (~5MB base).
# Much smaller than Ubuntu (~80MB) or Debian (~120MB).
FROM alpine:3.20

# Image labels for provenance tracking (which repo built this image)
LABEL org.opencontainers.image.source="https://github.com/dolr-ai/yral-rishi-hetzner-infra-template"
LABEL org.opencontainers.image.description="dolr-ai database backup (pg_dump + MinIO Client)"

# Install the packages we need:
#   postgresql16-client: includes pg_dump (the backup tool)
#   bash: the shell our backup.sh script is written in
#   coreutils: standard Unix tools (stat, date, etc.)
#   tzdata: timezone data (so dates in backup filenames are correct)
#
# "apk" is Alpine's package manager (like apt on Ubuntu).
# "--no-cache" means don't keep a local package index (saves space).
RUN apk add --no-cache \
    postgresql16-client \
    bash \
    coreutils \
    tzdata \
    && rm -rf /var/cache/apk/*

# Download MinIO Client (mc) — a single static binary for S3 operations.
#
# SECURITY: we verify the SHA256 checksum after downloading. If the
# download is tampered with (compromised CDN, man-in-the-middle attack),
# the checksum won't match and the build fails. This prevents a supply
# chain attack where an attacker replaces mc with a malicious version
# that steals your database dumps and S3 credentials.
#
# TO UPDATE mc: download the new version, compute its sha256sum, and
# replace the hash below.
RUN wget -q https://dl.min.io/client/mc/release/linux-amd64/mc -O /usr/local/bin/mc \
    && echo "01f866e9c5f9b87c2b09116fa5d7c06695b106242d829a8bb32990c00312e891  /usr/local/bin/mc" | sha256sum -c - \
    && chmod +x /usr/local/bin/mc

# Copy our backup script into the image and make it executable
COPY backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh

# When the container starts, run the backup script.
# The script: pg_dump → gzip → mc upload to S3 → verify → prune old backups.
CMD ["/usr/local/bin/backup.sh"]
