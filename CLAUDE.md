# yral-rishi-hetzner-infra-template

Canonical infrastructure template for dolr-ai services.
Live at **https://rishi-hetzner-infra-template.rishi.yral.com**

---

## What this repo is

A **config-driven, production-ready template** for any new FastAPI service
that needs HA Postgres, CI/CD, HTTPS, backups, and zero-downtime deploys.

Create a new service in one command:
```bash
bash scripts/new-service.sh --name my-service
```

The business logic lives in `app/main.py` + `app/database.py`. Everything
else (infra, CI, security, backups, migrations) is inherited from the template.

---

## Architecture

```
Browser
  ↓ Cloudflare wildcard *.rishi.yral.com (DNS round-robin to rishi-1 + rishi-2)
Caddy (rishi-1 OR rishi-2, per-project snippet in /etc/caddy/conf.d/)
  ↓ Docker "web" bridge network (local per server)
App (FastAPI, non-root appuser UID 1001, rishi-1 + rishi-2)
  ↓ Docker Swarm overlay network (per-project, private, encrypted)
HAProxy (rishi-1 + rishi-2, routes to Patroni leader via /master health check)
  ↓
PostgreSQL Primary (whichever of rishi-1/2/3 is current leader)
  ↕ streaming replication
PostgreSQL Standbys (the other 2 servers)
```

---

## Servers (from servers.config)

| Name | IP | Role |
|---|---|---|
| rishi-1 | 138.201.137.181 | Swarm manager + App + DB |
| rishi-2 | 136.243.150.84 | Swarm worker + App + DB |
| rishi-3 | 136.243.147.225 | Swarm worker + DB only |

To add a new server: `bash scripts/add-server.sh --name rishi-4 --ip X.X.X.X`
To migrate to new IPs: edit `servers.config`, re-run `scripts/swarm-setup.sh`.

---

## Config files (two sources of truth)

| File | Scope | Contains |
|---|---|---|
| `project.config` | Per-project | PROJECT_NAME, domain, DB name, image repos, backup config, WITH_DATABASE flag |
| `servers.config` | Shared across all projects | Server IPs, deploy user, SSH key path |

Every script, stack file, and CI workflow reads from these. Zero hardcoded IPs or names in runtime code.

---

## Deploy flow (canary + auto-rollback)

```
push to main
  → CI: gitleaks scan + unit tests + template integrity check
  → CI: build + push app image + patroni image + backup image to GHCR
  → CI: Trivy CRITICAL CVE gate (fails the build if found)
  → CI: deploy-db-stack (etcd + Patroni + HAProxy via Swarm)
  → CI: deploy-app to rishi-1 (CANARY):
      1. SCP files (compose, migrations, caddy snippet, scripts)
      2. Run migrations BEFORE new app starts (expand-contract)
      3. docker compose up -d (new image)
      4. Wait for healthy (Docker healthcheck, 5s interval, 30s start_period)
      5. Verify via Caddy round-trip curl
      6. If UNHEALTHY → auto-rollback to .last_good_image_tag, exit 1
      7. If HEALTHY → record tag, update Caddy snippet
  → CI: deploy-app to rishi-2 (ONLY if rishi-1 fully succeeded)
```

A bad deploy fails on rishi-1, auto-rolls back, and rishi-2 stays on the
old healthy image. Cloudflare DNS RR keeps serving via rishi-2.

---

## Database HA

| Component | Count | Role |
|---|---|---|
| etcd | 3 (one per server) | Leader election consensus |
| Patroni | 3 (one per server) | Manages Postgres, auto-promotes on failure |
| HAProxy | 2 (rishi-1 + rishi-2) | Routes app connections to current leader |

Failover time: ~12-30s. Tested and proven: 20/20 requests succeed during leader kill.

---

## Backups

Daily `pg_dump` to Hetzner Object Storage via GitHub Actions scheduled workflow.

- **Schedule:** daily at 3:00 AM UTC (`.github/workflows/backup.yml`)
- **Storage:** `s3://rishi-yral/<PROJECT_REPO>/daily/YYYY-MM-DD_HHMMSS.sql.gz`
- **Retention:** 7 daily + 4 weekly (configurable in project.config)
- **Isolation:** each service has its own S3 prefix — zero overlap
- **Manual trigger:** `gh workflow run backup.yml`
- **Restore:** `bash scripts/restore-from-backup.sh --latest`

---

## Migrations (zero-downtime)

Plain SQL files in `migrations/`, applied BEFORE the new app starts.

```bash
# Add a migration
echo "ALTER TABLE users ADD COLUMN IF NOT EXISTS email VARCHAR(255);" > migrations/002_add_email.sql
git push  # CI applies it before deploying new code
```

Rules: see `MIGRATIONS.md`. Key constraint: every migration must be
backward-compatible with the currently-running code (expand-contract pattern).

---

## Security posture

- App runs as **non-root `appuser`** (UID 1001) inside the container
- DB passwords in Docker Swarm secrets (files at `/run/secrets/`, never env vars)
- Caddy security headers: HSTS, CSP, COOP/COEP/CORP, X-Frame-Options DENY
- Request body cap: 100 MB
- Trivy CRITICAL CVEs fail the build
- gitleaks on every push
- Dependabot weekly scans (pip + Docker + Actions)
- `.bootstrap-secrets/` permanently gitignored
- No public debug endpoints

See `SECURITY.md` for the full threat model + deferred TODOs.

---

## File structure

| Path | Purpose |
|---|---|
| `project.config` | Single source of truth — project name, domain, DB, images, backup |
| `servers.config` | Server IPs + deploy user (shared across all projects) |
| `app/main.py` | FastAPI routes — **replace per project** |
| `app/database.py` | DB connection pool + atomic counter — **replace per project** |
| `infra/` | Reusable helpers: `init_sentry()`, `get_secret()`, `push_uptime_kuma()` |
| `migrations/` | Numbered SQL files — single source of truth for DB schema |
| `Dockerfile` | App image (python:3.12-slim, non-root) |
| `docker-compose.yml` | App container (rishi-1 + rishi-2, not Swarm) |
| `patroni/` | Patroni image + config + bootstrap scripts |
| `etcd/stack.yml` | etcd Swarm stack (3 nodes) |
| `haproxy/` | HAProxy config + Swarm stack (2 nodes) |
| `backup/` | Backup image (alpine + pg_dump + mc) |
| `caddy/snippet.caddy.template` | Per-project Caddy reverse proxy block |
| `local/` | Single-host dev stack (`bash local/setup.sh`) |
| `scripts/new-service.sh` | One-command bootstrap for a new service |
| `scripts/teardown-service.sh` | Full cleanup of a service from infra + GitHub |
| `scripts/add-server.sh` | Provision a new Hetzner server into the cluster |
| `scripts/swarm-setup.sh` | One-time Swarm cluster initialization |
| `scripts/ci/deploy-app.sh` | Canary deploy with auto-rollback |
| `scripts/ci/deploy-db-stack.sh` | Swarm stack deploy (etcd + Patroni + HAProxy) |
| `scripts/ci/run-migrations.sh` | Apply pending SQL migrations via HAProxy |
| `scripts/restore-from-backup.sh` | Download + restore from S3 backup |
| `scripts/rotate-secrets.sh` | Generate + set new DB passwords |
| `scripts/strip-database.sh` | Convert to stateless service (no DB) |
| `tests/` | Unit tests (pytest) + template integrity (shell) |
| `tests/integration/` | Manual failover + isolation + parity tests |
| `.github/workflows/deploy.yml` | CI/CD pipeline |
| `.github/workflows/backup.yml` | Scheduled daily backup |

---

## GitHub Secrets required per service

| Secret | Source |
|---|---|
| `HETZNER_BARE_METAL_GITHUB_ACTIONS_SSH_PRIVATE_KEY` | `cat ~/.ssh/rishi-hetzner-ci-key` |
| `POSTGRES_PASSWORD` | Generated by `new-service.sh` |
| `REPLICATION_PASSWORD` | Generated by `new-service.sh` |
| `DATABASE_URL_SERVER_1` | Composed by `new-service.sh` |
| `DATABASE_URL_SERVER_2` | Composed by `new-service.sh` |
| `BACKUP_S3_ACCESS_KEY` | Hetzner S3 credentials |
| `BACKUP_S3_SECRET_KEY` | Hetzner S3 credentials |
| `SENTRY_DSN` (optional) | From apm.yral.com |

`new-service.sh` sets the first 5 automatically. S3 + Sentry are set manually.

---

## Quick reference commands

```bash
# Create a new service
bash scripts/new-service.sh --name my-service

# Test locally
bash local/setup.sh && curl http://localhost:8080/

# Check Patroni cluster
ssh deploy@138.201.137.181 'docker exec $(docker ps -qf name=<stack>_patroni-rishi-1 | head -1) patronictl -c /etc/patroni.yml list'

# Trigger manual backup
gh workflow run backup.yml

# Restore from latest backup
bash scripts/restore-from-backup.sh --latest

# Preview pending migrations
APP_DIR=$(pwd) bash scripts/ci/run-migrations.sh --dry-run

# Run integration tests
bash tests/integration/run_all.sh

# Tear down a throwaway service
bash scripts/teardown-service.sh --name temp-test-1
```
