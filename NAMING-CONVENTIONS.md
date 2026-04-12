# Naming Conventions

Every identifier in a dolr-ai service is derived from ONE value: the
**PROJECT_NAME** in `project.config`. This document explains how every
name is generated, where it's used, and how to verify naming consistency.

---

## The single source: PROJECT_NAME

When you run `bash scripts/new-service.sh --name my-service`, the name
"my-service" becomes the seed for EVERY identifier:

| Variable | Pattern | Example (my-service) |
|---|---|---|
| `PROJECT_NAME` | `<name>` | `my-service` |
| `PROJECT_DOMAIN` | `<name>.rishi.yral.com` | `my-service.rishi.yral.com` |
| `PROJECT_REPO` | `yral-<name>` | `yral-my-service` |
| `POSTGRES_DB` | `<name_underscored>_db` | `my_service_db` |
| `PATRONI_SCOPE` | `<name>-cluster` | `my-service-cluster` |
| `ETCD_TOKEN` | `<name>-etcd-cluster` | `my-service-etcd-cluster` |
| `SWARM_STACK` | `<name>-db` | `my-service-db` |
| `OVERLAY_NETWORK` | `<name>-db-internal` | `my-service-db-internal` |
| `IMAGE_REPO` | `ghcr.io/dolr-ai/yral-<name>` | `ghcr.io/dolr-ai/yral-my-service` |
| `PATRONI_IMAGE_REPO` | `ghcr.io/dolr-ai/yral-<name>-patroni` | `ghcr.io/dolr-ai/yral-my-service-patroni` |

---

## Name rules

The PROJECT_NAME must follow these rules:

- **Lowercase only** — no uppercase letters
- **Alphanumeric + hyphens only** — no underscores, spaces, or special characters
- **Starts with a letter** — not a number or hyphen
- **Ends with a letter or number** — not a hyphen
- **Max 39 characters** — because Docker Swarm has a 63-character limit on
  secret names, and the longest name generated is
  `<name>-db_replication_password` (name + 24 characters)

**Valid names:** `my-service`, `nsfw-detection`, `crypto-bot`, `temp-test-3`
**Invalid names:** `MyService`, `my_service`, `-bad`, `bad-`, `123start`

---

## Where names appear (and how they're set)

### Runtime files (${VAR} interpolation from project.config)

These files read from `project.config` at runtime — the name is NEVER
hardcoded in these files:

| File | How it reads project.config |
|---|---|
| `docker-compose.yml` | `${IMAGE_REPO}`, `${PROJECT_REPO}` |
| `patroni/stack.yml` | `${PATRONI_IMAGE_REPO}`, `${PATRONI_SCOPE}`, `${OVERLAY_NETWORK}` |
| `etcd/stack.yml` | `${ETCD_TOKEN}`, `${OVERLAY_NETWORK}` |
| `haproxy/stack.yml` | `${OVERLAY_NETWORK}` |
| `caddy/snippet.caddy.template` | `${PROJECT_DOMAIN}`, `${PROJECT_REPO}` |
| `scripts/ci/deploy-app.sh` | sources `project.config` |
| `scripts/ci/deploy-db-stack.sh` | sources `project.config` |
| `scripts/ci/run-migrations.sh` | sources `project.config` |
| `.github/workflows/deploy.yml` | parses `project.config` into `$GITHUB_ENV` |
| `.github/workflows/infra-health.yml` | parses `project.config` into `$GITHUB_ENV` |
| `.github/workflows/backup.yml` | parses `project.config` into `$GITHUB_ENV` |

**These files need NO modification when creating a new service.** Changing
`project.config` is enough.

### Static files (hardcoded — replaced by init-from-template.sh)

These files have the project name HARDCODED in them. The `init-from-template.sh`
script replaces all occurrences of the template name with the new name:

| File | What's hardcoded |
|---|---|
| `Dockerfile` | `LABEL org.opencontainers.image.source=` (GitHub repo URL) |
| `backup/Dockerfile` | Same LABEL |
| `patroni/Dockerfile` | Same LABEL |
| `CLAUDE.md` | Project title, live URL, architecture description |
| `README.md` | Project title, live URL, curl examples, project.config example |
| `DEEP-DIVE.md` | Request flow walkthrough, config examples, diagrams |
| `READING-ORDER.md` | Directory tree root name |
| `RUNBOOK.md` | Example stack names, script paths |

**init-from-template.sh handles ALL of these automatically.** You should
never need to manually search-and-replace.

---

## GitHub resources (created by new-service.sh)

| Resource | Name | Example |
|---|---|---|
| GitHub repo | `dolr-ai/yral-<name>` | `dolr-ai/yral-my-service` |
| GHCR app image | `ghcr.io/dolr-ai/yral-<name>` | `ghcr.io/dolr-ai/yral-my-service` |
| GHCR patroni image | `ghcr.io/dolr-ai/yral-<name>-patroni` | `ghcr.io/dolr-ai/yral-my-service-patroni` |
| GHCR backup image | `ghcr.io/dolr-ai/yral-<name>-backup` | `ghcr.io/dolr-ai/yral-my-service-backup` |

---

## Infrastructure resources (created by CI on first deploy)

| Resource | Name | Scope |
|---|---|---|
| Docker Swarm stack | `<name>-db` | Cluster-wide |
| Overlay network | `<name>-db-internal` | Cluster-wide |
| Swarm secret (postgres) | `<name>-db_postgres_password` | Cluster-wide |
| Swarm secret (replication) | `<name>-db_replication_password` | Cluster-wide |
| Patroni volumes | `<name>-db_patroni-rishi-{1,2,3}-data` | Per-server |
| etcd volumes | `<name>-db_etcd-rishi-{1,2,3}-data` | Per-server |
| App container | `yral-<name>` | Per-server (rishi-1 + rishi-2) |
| Caddy snippet | `/home/deploy/caddy/conf.d/yral-<name>.caddy` | Per-server |
| App directory | `/home/deploy/yral-<name>/` | Per-server |
| Stack files directory | `/home/deploy/<name>-db-stack/` | rishi-1 only |
| S3 backup prefix | `s3://rishi-yral/yral-<name>/daily/` | Hetzner Object Storage |
| Cloudflare DNS | `<name>.rishi.yral.com` | Wildcard, automatic |

---

## How to verify naming consistency

### Automated (CI runs this on every push)

The `tests/test_template_integrity.sh` script checks:
- All Dockerfiles have `LABEL org.opencontainers.image.source` pointing to
  the correct GitHub repo (not the template's)
- No `.md` files reference the template name (unless this IS the template)

### Manual

Run this from the project root to find any template references:

```bash
grep -rIn --exclude-dir=.git --exclude-dir=.venv \
  'rishi-hetzner-infra-template' . \
  | grep -v 'init-from-template.sh' \
  | grep -v 'NAMING-CONVENTIONS.md'
```

If this returns results, the naming isn't clean. Run:
```bash
bash scripts/init-from-template.sh <your-project-name>
```

---

## Common naming mistakes

| Mistake | Why it happens | How to fix |
|---|---|---|
| Dockerfiles still reference template | `init-from-template.sh` was an older version that only updated `project.config` | Re-run `init-from-template.sh` (latest version updates all files) |
| Docs have template URLs | Same cause | Same fix |
| Migration 001 has template content | Replaced 001's contents instead of creating 002 | Add your schema as `002_your_schema.sql`; see MIGRATIONS.md |
| S3 backups go to wrong prefix | `project.config` BACKUP_S3_BUCKET or PROJECT_REPO wrong | Check `project.config` values |
| Two services share the same Swarm secret name | SWARM_STACK collision (same PROJECT_NAME) | Each service MUST have a unique PROJECT_NAME |
