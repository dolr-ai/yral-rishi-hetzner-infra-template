# Lightweight backup container: pg_dump + MinIO client (mc) for S3 uploads.
# Uses mc instead of aws-cli because aws-cli v2 on Alpine crashes with
# Hetzner Object Storage's error responses. mc is a single binary that
# works reliably with any S3-compatible service.
FROM alpine:3.20

RUN apk add --no-cache \
    postgresql16-client \
    bash \
    coreutils \
    tzdata \
    && rm -rf /var/cache/apk/*

# Install MinIO Client (mc) — single static binary
RUN wget -q https://dl.min.io/client/mc/release/linux-amd64/mc -O /usr/local/bin/mc \
    && chmod +x /usr/local/bin/mc

COPY backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh

CMD ["/usr/local/bin/backup.sh"]
