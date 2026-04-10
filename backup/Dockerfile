# Lightweight backup container: pg_dump + aws-cli + cron.
# Runs on rishi-1 only via Swarm placement constraint.
FROM alpine:3.20

RUN apk add --no-cache \
    postgresql16-client \
    aws-cli \
    bash \
    coreutils \
    tzdata \
    && rm -rf /var/cache/apk/*

COPY backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh

# Default: run the backup once then exit (Swarm restart_policy handles
# the schedule via the deploy config in stack.yml). If you want cron-based
# scheduling inside the container instead, override CMD.
CMD ["/usr/local/bin/backup.sh"]
