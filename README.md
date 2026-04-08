# yral-rishi-hetzner-infra-template

The canonical infrastructure template for any new dolr-ai service that needs:
- Stateless FastAPI app on rishi-1 + rishi-2
- Fully redundant 3-node PostgreSQL via Patroni + etcd + HAProxy on Docker Swarm
- HTTPS via Caddy + Cloudflare (per-project snippet, zero coupling to other services)
- CI/CD via GitHub Actions (deploy as `deploy` user, no root)
- Sentry error reporting + image SHA tagging
- **A `local/` directory that runs the entire production stack on your Mac in ~10 seconds**

The template is **config-driven**: edit ONE file (`project.config`) and every infra
file picks up the new project name, domain, database, etcd token, network, etc.
No sed-across-the-repo. No Caddyfile coordination between projects.

This repo is **also a live working service** at
**https://rishi-hetzner-infra-template.rishi.yral.com** — a counter app that
proves the template produces a fully working independent service.

---

## Quick start (existing service)

```bash
# Run the live counter from the production deploy
curl https://rishi-hetzner-infra-template.rishi.yral.com/
```

## Quick start (local dev)

```bash
# Make sure Docker Desktop is running
open -a Docker

# Bring up the entire 8-container stack on your laptop in ~10 seconds
bash local/setup.sh

# Test
curl http://localhost:8080/

# Inspect the local Patroni cluster
docker exec patroni-rishi-1 patronictl -c /etc/patroni.yml list

# Tear down
bash local/teardown.sh
```

See [`local/README.md`](local/README.md) for full local-dev docs.

## Quick start (start a NEW service from this template)

The canonical, one-command flow:

```bash
cd ~/Claude\ Projects/yral-rishi-hetzner-infra-template
bash scripts/new-service.sh --name my-service     # name must be ≤39 chars
```

This single command does ALL of: cp the template → run init-from-template
→ generate strong secrets → `gh repo create` → push → set all 5 GitHub
Secrets → watch the first CI run → verify `https://my-service.rishi.yral.com/health`.
When it exits 0, the service is live in production.

Then write your business logic:

```bash
cd ~/Claude\ Projects/yral-my-service
# Edit app/main.py + app/database.py with your routes/queries
# Edit patroni/init.sql with your DB schema (or run scripts/strip-database.sh
# if your service is stateless)
bash local/setup.sh                # spin the full stack on your Mac
curl http://localhost:8080/        # verify business logic
git add -A && git commit -m "..." && git push    # CI redeploys
```

Validate end-to-end with the integration suite:

```bash
bash tests/integration/run_all.sh
```

All 4 tests must pass: server failover, server+leader failover, project
isolation, image parity.

To tear down a throwaway service:

```bash
bash scripts/teardown-service.sh --name my-service
```

That's it. No sed across the repo, no Caddyfile coordination, no per-file
hunting for hardcoded names.

---

## How the templating works

Single source of truth: **`project.config`** at the repo root.

```bash
# project.config
PROJECT_NAME=rishi-hetzner-infra-template
PROJECT_DOMAIN=rishi-hetzner-infra-template.rishi.yral.com
PROJECT_REPO=yral-rishi-hetzner-infra-template
POSTGRES_DB=rishi_hetzner_infra_template_db
PATRONI_SCOPE=rishi-hetzner-infra-template-cluster
ETCD_TOKEN=rishi-hetzner-infra-template-etcd-cluster
SWARM_STACK=rishi-hetzner-infra-template-db
OVERLAY_NETWORK=rishi-hetzner-infra-template-db-internal
IMAGE_REPO=ghcr.io/dolr-ai/yral-rishi-hetzner-infra-template
PATRONI_IMAGE_REPO=ghcr.io/dolr-ai/yral-rishi-hetzner-infra-template-patroni
```

Every other file references these via `${VAR}` interpolation:
- **Stack files** (`etcd/stack.yml`, `patroni/stack.yml`, `haproxy/stack.yml`) — Compose v3 + `docker stack deploy` natively support `${VAR}` substitution from the shell environment
- **App `docker-compose.yml`** — same `${VAR}` pattern
- **`local/setup.sh`** sources `project.config` with `set -a` before `docker compose up`
- **`scripts/ci/deploy-*.sh`** sources `project.config` on the server
- **`.github/workflows/deploy.yml`** parses `project.config` into `$GITHUB_ENV` once per job
- **`patroni/patroni.yml`** uses Patroni's native `PATRONI_SCOPE` env var override (Patroni doesn't do YAML interpolation, but env var overrides win)

## Caddy decoupling

Caddy is a **shared platform service** on rishi-1 and rishi-2. The wrapper
`/home/deploy/caddy/Caddyfile` is just `import /etc/caddy/conf.d/*.caddy`.
Each project drops a single file `/home/deploy/caddy/conf.d/${PROJECT_REPO}.caddy`
and runs `caddy reload`. Each project owns ONLY its own snippet — never reads
or writes any other project's file.

This means deploying this template never touches `yral-hello-world-counter`
or `yral-hello-world-rishi`, and vice-versa.

---

## Repo structure

| Path | What it is |
|---|---|
| `project.config` | **Single source of truth** — every infra file references these vars |
| `app/` | FastAPI business logic (`main.py`, `database.py`) — replace per project |
| `patroni/init.sql` | DB schema — replace per project |
| `patroni/Dockerfile` | Custom PostgreSQL 16 + Patroni image (rebuilt on every deploy) |
| `patroni/patroni.yml` | Patroni config (uses placeholder for scope/name; PATRONI_SCOPE env var overrides) |
| `patroni/post_init.sh` | Bootstrap SQL (creates DB from POSTGRES_DB env var, runs init.sql) |
| `patroni/entrypoint.sh` | Loads Docker secrets into Patroni env vars |
| `patroni/stack.yml` | Docker Swarm stack for 3-node Patroni cluster |
| `etcd/stack.yml` | Docker Swarm stack for 3-node etcd cluster |
| `haproxy/stack.yml` | Docker Swarm stack for 2-node HAProxy (routes to Patroni leader) |
| `haproxy/haproxy.cfg` | HAProxy routing config |
| `caddy/snippet.caddy.template` | Per-project Caddy block, rendered at deploy time |
| `docker-compose.yml` | Counter app (regular compose, not Swarm) |
| `local/` | **Single-host setup** for laptop dev (3 etcd + 3 Patroni + HAProxy + app) |
| `local/setup.sh` | One-command bring-up |
| `local/teardown.sh` | Stop all + delete volumes |
| `scripts/ci/deploy-db-stack.sh` | CI step: deploy Swarm stack via SSH to rishi-1 |
| `scripts/ci/deploy-app.sh` | CI step: deploy app + write Caddy snippet via SSH |
| `scripts/init-from-template.sh` | Rename script — edits only `project.config` |
| `scripts/swarm-setup.sh` | One-time Swarm bootstrap (run once per cluster) |
| `.github/workflows/deploy.yml` | CI/CD pipeline |
| `TEMPLATE.md` | How to use this as a template for a new service |
| `CLAUDE.md` | Architecture deep-dive |

---

## Status

- ✅ Live in production with full HA
- ✅ Local dev parity (same Docker images, same configs, single-host)
- ✅ Failover tested
- ✅ Database not accessible from internet
- ✅ Passwords as Docker Swarm secrets (not env vars)
- ✅ Per-project overlay network (no DNS conflicts with other projects)
- ✅ Per-project Caddy snippet (zero coupling to other projects)
- ✅ Sentry release tagging
- ✅ Connection pool with retry on dead connections
- ✅ Immutable image versioning via git SHA tags
- ✅ Config-driven: edit `project.config`, everything else flows
