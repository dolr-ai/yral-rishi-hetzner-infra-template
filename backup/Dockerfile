# Lightweight backup container: pg_dump + MinIO client (mc) for S3 uploads.
# Uses mc instead of aws-cli because aws-cli v2 on Alpine crashes with
# Hetzner Object Storage's error responses. mc is a single binary that
# works reliably with any S3-compatible service.
FROM alpine:3.20

LABEL org.opencontainers.image.source="https://github.com/dolr-ai/yral-rishi-hetzner-infra-template"
LABEL org.opencontainers.image.description="dolr-ai database backup (pg_dump + MinIO Client)"

RUN apk add --no-cache \
    postgresql16-client \
    bash \
    coreutils \
    tzdata \
    && rm -rf /var/cache/apk/*

# Install MinIO Client (mc) — single static binary with SHA256 verification.
# Pin the checksum to prevent supply chain attacks (compromised CDN → attacker
# gets DB dumps + S3 creds). Update this hash when upgrading mc.
RUN wget -q https://dl.min.io/client/mc/release/linux-amd64/mc -O /usr/local/bin/mc \
    && echo "01f866e9c5f9b87c2b09116fa5d7c06695b106242d829a8bb32990c00312e891  /usr/local/bin/mc" | sha256sum -c - \
    && chmod +x /usr/local/bin/mc

COPY backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh

CMD ["/usr/local/bin/backup.sh"]
