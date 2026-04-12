# Using this repo as a template for a new dolr-ai service

This repo is the production-ready template for any new dolr-ai service that needs:
- A stateless FastAPI app on rishi-1 + rishi-2
- A fully redundant PostgreSQL backend (Patroni + etcd + HAProxy via Docker Swarm)
- CI/CD via GitHub Actions, deploying as the `deploy` user (no root)
- Caddy reverse proxy with Cloudflare in front
- Sentry error monitoring
- Docker Swarm secrets for passwords (not env vars)
- Immutable image versioning via git SHA tags

The infrastructure layer is reusable as-is. Only the **app layer** (`app/`,
`patroni/init.sql`) needs to change per project.

---

## Security/operational features baked in

| Feature | What it does | Where |
|---|---|---|
| **Docker Swarm secrets** | Passwords mounted as files in `/run/secrets/` (tmpfs), never visible in `docker inspect` | `patroni/stack.yml`, `patroni/entrypoint.sh`, `patroni/post_init.sh` |
| **Compose secret files** | App reads `DATABASE_URL` from `/run/secrets/database_url`, not env var | `docker-compose.yml`, `app/database.py` |
| **Git SHA image tags** | Every CI build pushes `:${git-sha}` AND `:latest`. Stack uses SHA. Rollback by deploying an older SHA | `.github/workflows/deploy.yml` |
| **Connection pooling** | psycopg2 `ThreadedConnectionPool` (min=2, max=10) instead of fresh connections per request | `app/database.py` |
| **Minimum-privilege rewind_user** | Patroni's pg_rewind user has only catalog read perms, NOT superuser | `patroni/post_init.sh` |
| **CI scripts in files** | Deploy logic in `scripts/ci/*.sh`, not inline in workflow YAML — readable, testable | `scripts/ci/deploy-db-stack.sh`, `scripts/ci/deploy-app.sh` |
| **Private DB network** | etcd + Patroni + HAProxy on `db-internal` Swarm overlay (not internet-accessible) | `patroni/stack.yml`, `etcd/stack.yml`, `haproxy/stack.yml` |
| **Sentry error reporting** | App errors auto-reported to apm.yral.com | `app/main.py`, `requirements.txt` |
| **Idempotent bootstrap** | post_init.sh + init.sql can be re-run without breaking | `patroni/post_init.sh`, `patroni/init.sql` |

---

## What's reusable vs project-specific

| Layer | Files | Action |
|---|---|---|
| **Swarm/HA infra** | `etcd/`, `patroni/Dockerfile`, `patroni/patroni.yml`, `patroni/post_init.sh`, `patroni/entrypoint.sh`, `patroni/stack.yml`, `haproxy/`, `scripts/swarm-setup.sh` | Reuse as-is (only string renames) |
| **CI/CD** | `.github/workflows/deploy.yml`, `scripts/ci/*.sh` | Reuse as-is (only string renames) |
| **Caddy** | `caddy/Caddyfile`, `caddy/docker-compose.yml` | Add new service block, keep existing ones |
| **App code** | `app/main.py`, `app/database.py`, `requirements.txt`, `Dockerfile`, `docker-compose.yml` | **Rewrite for new app** |
| **DB schema** | `patroni/init.sql` | **Rewrite for new schema** |

---

## One-command bootstrap (canonical flow)

From inside this template repo:

```bash
bash scripts/new-service.sh --name <bare-name>
# example:
bash scripts/new-service.sh --name my-service
```

That single command does ALL of the following:

1. Validates prerequisites (`gh` auth, `openssl`, CI SSH key, name length ≤39 chars)
2. Copies the template to `~/Claude Projects/yral-<name>/`
3. Runs `scripts/init-from-template.sh` (renames identifiers in `project.config`)
4. Generates strong `POSTGRES_PASSWORD` + `REPLICATION_PASSWORD` via `openssl rand -hex 32`
5. Composes the two `DATABASE_URL_SERVER_*` values
6. `git init` + initial commit
7. `gh repo create dolr-ai/yral-<name> --public`
8. `git push -u origin main`
9. Sets all 7 GitHub Secrets automatically:
   - `HETZNER_BARE_METAL_GITHUB_ACTIONS_SSH_PRIVATE_KEY` (from `~/.ssh/rishi-hetzner-ci-key`)
   - `POSTGRES_PASSWORD` + `REPLICATION_PASSWORD` (generated via openssl)
   - `DATABASE_URL_SERVER_1` + `DATABASE_URL_SERVER_2` (composed from above)
   - `BACKUP_S3_ACCESS_KEY` + `BACKUP_S3_SECRET_KEY` (from macOS Keychain)
   Backups work from day one — no manual S3 secret setup needed.
10. Watches the first CI run to completion
11. Verifies `https://<name>.rishi.yral.com/health` returns 200

When the script exits 0, the service is **live in production** and you can hit the URL. Total time: ~5 minutes.

Then write your business logic:

```bash
cd ~/Claude\ Projects/yral-<name>
# Edit app/main.py + app/database.py with your routes/queries
# Edit patroni/init.sql with your DB schema (or delete + run scripts/strip-database.sh for stateless)
# Test locally:
bash local/setup.sh
curl http://localhost:8080/
# When happy:
git add -A && git commit -m "..." && git push  # CI redeploys
```

Validate the new service end-to-end with the integration suite:

```bash
bash tests/integration/run_all.sh
```

All 4 tests must pass: server failover, server+leader failover, project isolation, image parity.

### One-time prerequisite: S3 backup credentials in macOS Keychain

Before creating your first service, store the shared S3 credentials in
macOS Keychain (encrypted, never on disk). This is done ONCE and reused
by every future `new-service.sh` invocation:

```bash
security add-generic-password -a "dolr-ai" -s "BACKUP_S3_ACCESS_KEY" -w "YOUR_ACCESS_KEY" -U
security add-generic-password -a "dolr-ai" -s "BACKUP_S3_SECRET_KEY" -w "YOUR_SECRET_KEY" -U
```

Get the keys from the Hetzner Object Storage console. If already set up,
`new-service.sh` reads them automatically — nothing to do.

### Need to add Sentry?

Sentry is opt-in. Pass `--sentry-dsn` to bootstrap, or set the secret manually later:

```bash
gh secret set SENTRY_DSN -b 'https://...@apm.yral.com/...' --repo dolr-ai/yral-<name>
```

The `init_sentry()` helper in `infra/sentry.py` is a no-op when the env var is empty.

### Tearing down a service (e.g. throwaway test services)

```bash
bash scripts/teardown-service.sh --name <bare-name>
```

Removes the Swarm stack, volumes, secrets, network, app dir, Caddy snippet, GHCR images, GitHub repo, and local clone. Cross-project safe — never touches other services.

### Manual fallback (if you want to skip the bootstrap)

The old way is still in `scripts/init-from-template.sh`. Inspect that file for the manual steps. The bootstrap script just automates them.

---

## Things you do NOT need to redo (one-time, already done globally)

These are global to all dolr-ai services on rishi-1/rishi-2/rishi-3:
- ✅ `deploy` user exists with CI key
- ✅ Docker Swarm cluster initialized (rishi-1 manager, rishi-2/3 workers)
- ✅ Node labels (`server=rishi-1/2/3`)
- ✅ `db-internal` overlay network
- ✅ `web` Docker network
- ✅ Caddy running on rishi-1 and rishi-2
- ✅ Swarm infrastructure ports (2377/7946/4789) open

If you ever rebuild a server from scratch: `bash scripts/swarm-setup.sh`

---

## Rollback to a specific version

Every CI run pushes images tagged with the git SHA. To roll back:

```bash
# 1. Find the SHA you want to roll back to
git log --oneline

# 2. SSH into the manager and update the stack with that SHA
ssh deploy@rishi-1
cd /home/deploy/counter-db-stack
IMAGE_TAG=<old-sha> docker stack deploy --with-registry-auth \
    --compose-file etcd-stack.yml \
    --compose-file patroni-stack.yml \
    --compose-file haproxy-stack.yml \
    counter-db

# 3. For the app, do the same with docker-compose on rishi-1 and rishi-2
ssh deploy@rishi-1
cd /home/deploy/yral-hello-world-counter
IMAGE_TAG=<old-sha> docker compose up -d
```

Or just `git revert` the bad commit and let CI deploy normally.

---

## Things to think about before reusing this template for a new service

1. **Do you actually need PostgreSQL?**
   If your service is stateless or only stores metadata in object storage,
   delete `etcd/`, `patroni/`, `haproxy/`, `scripts/swarm-setup.sh`, and the
   `deploy-db-stack` job in the workflow. Massive simplification.

2. **Hardware constraints to know about:**
   - rishi-1/2/3 are CPU-only — **no GPUs**. If your service needs one, this
     template doesn't fit; you'll need different hardware.
   - For ML inference services in general: **load the model once at startup**
     and keep it in memory (never per-request).
   - For services that handle blobs (images, video, audio): use **object
     storage (Cloudflare R2 / Backblaze B2)** for the data, not PostgreSQL
     `bytea`. The DB is for metadata and references only.
   - For services with public endpoints that do real work: **add rate
     limiting** (see the commented `rate_limit` block in
     `caddy/snippet.caddy.template` — needs a custom Caddy build with
     `caddy-ratelimit`).
   - For long-running work: return a job ID and process in the background
     via a queue (Redis / NATS) instead of holding the HTTP request open.

---

## Deferred improvements (TODO — not blocking, do when needed)

These need infrastructure decisions or are too risky to do without testing.
Track them here so they don't get lost:

### High value, needs decision
- [ ] **Database backups** — daily `pg_dump` to S3-compatible storage. Decide:
      Cloudflare R2? Backblaze B2? Tigris? Then add a cron service to the stack.
- [ ] **Cluster monitoring** — Sentry catches app errors but NOT "Patroni leader gone"
      or "etcd lost quorum". Decide between:
      (a) Beszel (already running) + custom probe scripts
      (b) Prometheus + Grafana on a fourth server
      (c) Patroni's REST `/cluster` endpoint scraped by Uptime Kuma
- [ ] **Tighter Postgres pg_hba** — currently `0.0.0.0/0 md5`. Should be the
      `db-internal` overlay subnet only (e.g. `10.0.1.0/24`). The subnet is
      assigned by Swarm at network creation; needs research to make stable.

### Medium value
- [ ] **Staging environment** — currently every push goes to prod. Options:
      separate stack name `counter-db-staging` + `staging.rishi.yral.com`
      subdomain on the SAME servers (cheap), or new servers (expensive).
- [ ] **Service-specific test coverage** — the template ships with smoke
      tests for the counter; new services should add their own pytest tests
      for their routes and mocked-out external dependencies before the
      `test` job in CI gates the build.
- [ ] **Caddy rate limiting** — `caddy-ratelimit` plugin per-IP per-endpoint.
      Important for any service with public endpoints that do real work.
- [ ] **PgBouncer** — connection pooling AT THE PROXY LEVEL (in addition to the
      app-level pool). Useful when you have many app instances or high connection
      churn. Sits between HAProxy and Patroni.

### Lower value / optional
- [ ] **UFW default-deny** on rishi-1 and rishi-2 with explicit allow for
      22, 80, 443, 2377, 7946, 4789. Currently UFW is inactive on these servers
      so anything that binds is internet-exposed. Risky to enable remotely without
      console access — schedule a maintenance window.
- [ ] **SSH hardening** — disable root login, disable password auth, fail2ban.
      Saikat's Ansible may already handle some of this.
- [ ] **Image vulnerability scanning** — add `trivy` or `grype` to CI to flag
      CVEs in base images.
- [ ] **Secret rotation** — currently rotating `POSTGRES_PASSWORD` requires manual
      `docker secret rm` then redeploy AND `ALTER USER postgres WITH PASSWORD`.
      Could be scripted.
- [ ] **Graceful shutdown** — FastAPI should drain in-flight requests on SIGTERM
      before exiting. Add to `app/main.py`.

---

## Why some "improvements" weren't done

- **Caddy `tls internal` cert pinning** — not actually a problem. Cloudflare is
  in front and provides the public cert. Origin cert pinning by clients would
  be an anti-pattern in our setup.
- **Removing HAProxy** — Patroni has built-in DNS but the way it works requires
  client retry logic. HAProxy's transparent failover is simpler for the app.
