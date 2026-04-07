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

## Step-by-step for a new service (e.g. yral-nsfw-detection)

### 1. Copy and rename
```bash
cp -r "Claude Projects/hello-world-counter" "Claude Projects/nsfw-detection"
cd "Claude Projects/nsfw-detection"
rm -rf .git
bash scripts/init-from-template.sh nsfw-detection
```

### 2. Replace app code (manual)
- Rewrite `app/main.py` with new routes
- Rewrite `app/database.py` (or delete if no DB needed)
- Update `requirements.txt`
- Rewrite `patroni/init.sql` with new schema (or leave empty)

### 3. Update Caddyfile (in BOTH this repo AND every existing service repo)
The Caddyfile gets replaced on every deploy, so all services need to know
about each other. Add a block for the new service in every existing repo's
`caddy/Caddyfile`.

### 4. Create the GitHub repo
```bash
gh repo create dolr-ai/yral-nsfw-detection --public
```

### 5. Add 9 GitHub secrets
| Secret | Value |
|---|---|
| `SERVER_1_IP` | `138.201.137.181` |
| `SERVER_2_IP` | `136.243.150.84` |
| `SERVER_3_IP` | `136.243.147.225` |
| `HETZNER_BARE_METAL_GITHUB_ACTIONS_SSH_PRIVATE_KEY` | `cat ~/.ssh/rishi-hetzner-ci-key` |
| `SENTRY_DSN` | New project DSN from apm.yral.com |
| `POSTGRES_PASSWORD` | `openssl rand -hex 32` (URL-safe!) |
| `REPLICATION_PASSWORD` | `openssl rand -hex 32` |
| `DATABASE_URL_SERVER_1` | `postgresql://postgres:<PG_PASS>@<service>-db_haproxy-rishi-1:5432/<service>_db` |
| `DATABASE_URL_SERVER_2` | `postgresql://postgres:<PG_PASS>@<service>-db_haproxy-rishi-2:5432/<service>_db` |

### 6. Initial git push → CI auto-deploys
```bash
git init && git add -A && git commit -m "Initial commit" && git remote add origin git@github.com:dolr-ai/yral-<name>.git && git push -u origin main
```

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

2. **For NSFW detection specifically:**
   - You probably want **object storage (R2/B2)** for input images, not PostgreSQL bytea
   - You may want **async processing** (return job ID, process in background) → needs Redis or NATS queue
   - **No GPUs** on rishi-1/2/3 — if your model needs one, this template doesn't fit
   - **Load model once at startup**, keep in memory (don't reload per request)
   - **Add rate limiting** (NSFW endpoints get DoSed)

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
- [ ] **Automated tests** — for the counter app there's barely anything to test.
      For NSFW detection, write pytest tests for the route + a mocked model.
      Add a `test` job to the workflow that runs before `build-and-push`.
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
