# Architecture — yral-rishi-hetzner-infra-template

Counter service at `dolr-ai/yral-rishi-hetzner-infra-template`.
Live at `https://rishi-hetzner-infra-template.rishi.yral.com`

---

## What it does

Every GET / request returns the next visitor number:
- Person 1 → `{"message": "Hello World Person 1"}`
- Person 2 → `{"message": "Hello World Person 2"}`

The counter is stored in PostgreSQL (survives restarts). The database
is fully redundant across 3 servers with automatic failover.

---

## Architecture

```
Browser
  ↓ Cloudflare wildcard *.rishi.yral.com → rishi-1 AND rishi-2
Caddy (on rishi-1 OR rishi-2)
  ↓ Docker "web" network
Counter App (FastAPI, on rishi-1 AND rishi-2)
  ↓ Docker "web" network
HAProxy (haproxy-rishi-1 OR haproxy-rishi-2, Swarm service)
  ↓ Docker "db-internal" overlay network (private, encrypted, not internet-accessible)
  ↓ checks Patroni /master endpoint every 3 seconds
PostgreSQL Primary (on whichever of rishi-1/2/3 is current leader)
  ↕ streaming replication (also via db-internal overlay)
PostgreSQL Standbys (the other 2 servers)
```

---

## Servers

| Name    | IP               | Role |
|---------|-----------------|------|
| rishi-1 | 138.201.137.181 | App + DB + Swarm manager |
| rishi-2 | 136.243.150.84  | App + DB + Swarm worker  |
| rishi-3 | 136.243.147.225 | DB only + Swarm worker   |

---

## Docker Networks

Two Docker networks:

| Network | Type | Who's on it | Accessible from internet? |
|---|---|---|---|
| `web` | Bridge (local per server) | Caddy, App, HAProxy | Ports 80+443 only |
| `db-internal` | Swarm overlay (spans all 3 servers) | etcd, Patroni, HAProxy | NO — completely private |

The `db-internal` overlay is the key security feature. etcd and PostgreSQL
are invisible to the internet. No firewall rules needed for application ports.

---

## Database HA (High Availability)

### Components

| Component | What it does |
|---|---|
| **etcd** (3 nodes, one per server) | Distributed "scoreboard" — all servers agree on who is primary |
| **Patroni** (3 nodes, one per server) | Manages PostgreSQL; uses etcd for leader election; auto-promotes on failure |
| **HAProxy** (on rishi-1, rishi-2) | Routes app DB connections to current primary via Patroni /master health check |

### Why 3 servers for the database

With 2 servers, if one loses contact with the other, neither can safely decide
if the other is dead or just experiencing a network blip. Promoting a standby
when the primary is still alive causes split-brain (data corruption).

With 3 servers: 2 out of 3 must agree a node is dead before promoting a new primary.
This is a quorum vote. It's safe because a network partition cannot give a majority
to both sides simultaneously.

### Failover time

~30 seconds (Patroni's default ttl=30 + election time).

### Checking cluster status

SSH into any server and run:
```bash
docker exec $(docker ps -qf name=patroni-rishi-1) patronictl -c /etc/patroni.yml list
```

---

## Docker Swarm

This service uses Docker Swarm for the database tier. Swarm is what makes
`etcd/stack.yml`, `patroni/stack.yml`, and `haproxy/stack.yml` work
across multiple servers.

### Key concepts

- **Manager node**: rishi-1. All `docker stack deploy` commands go here.
- **Worker nodes**: rishi-2, rishi-3. Swarm sends containers there automatically.
- **Node labels**: Each node is tagged `server=rishi-X`. Stack files use placement
  constraints to pin specific containers to specific servers.
- **Overlay network**: `db-internal` is a Swarm overlay — private encrypted network
  spanning all 3 servers. Containers on it talk by service name, not IP.

### One-time Swarm setup

Run once: `bash scripts/swarm-setup.sh`

This opens Swarm infrastructure ports, initializes the cluster, adds node labels,
and creates the `db-internal` network. Never needs to run again.

---

## Atomic counter (no race conditions)

```sql
UPDATE counter SET value = value + 1 WHERE id = 1 RETURNING value;
```

One atomic SQL statement — safe even with 1000 simultaneous visitors.

---

## Files

| File | Purpose |
|---|---|
| `app/main.py` | FastAPI routes (/, /health) |
| `app/database.py` | PostgreSQL connection + atomic counter logic |
| `Dockerfile` | Counter app container |
| `requirements.txt` | Python dependencies |
| `docker-compose.yml` | Counter app (rishi-1, rishi-2) — regular compose, not Swarm |
| `etcd/stack.yml` | etcd cluster (all 3 servers via Swarm placement) |
| `patroni/Dockerfile` | Custom PostgreSQL 16 + Patroni image |
| `patroni/stack.yml` | Patroni cluster (all 3 servers via Swarm placement) |
| `patroni/patroni.yml` | Patroni configuration (uses service names, not IPs) |
| `patroni/post_init.sh` | Runs ONCE on first bootstrap: creates rishi_hetzner_infra_template_db + counter table |
| `patroni/init.sql` | SQL for counter table |
| `haproxy/stack.yml` | HAProxy (rishi-1 + rishi-2 via Swarm placement) |
| `haproxy/haproxy.cfg` | HAProxy routing config (uses Patroni service names) |
| `caddy/Caddyfile` | BOTH service routing blocks |
| `caddy/docker-compose.yml` | Caddy container |
| `.github/workflows/deploy.yml` | CI/CD pipeline |
| `scripts/swarm-setup.sh` | ONE-TIME Swarm initialization (uses root SSH) |
| `scripts/rishi3-setup.sh` | ONE-TIME setup for rishi-3 deploy user |

---

## GitHub Secrets required

| Secret | Value |
|---|---|
| `SERVER_1_IP` | 138.201.137.181 |
| `SERVER_2_IP` | 136.243.150.84 |
| `SERVER_3_IP` | 136.243.147.225 |
| `HETZNER_BARE_METAL_GITHUB_ACTIONS_SSH_PRIVATE_KEY` | `cat ~/.ssh/rishi-hetzner-ci-key` |
| `SENTRY_DSN` | From apm.yral.com (new project for this service) |
| `POSTGRES_PASSWORD` | Strong random password (`openssl rand -base64 32`) |
| `REPLICATION_PASSWORD` | Different strong random password |
| `DATABASE_URL_SERVER_1` | `postgresql://postgres:POSTGRES_PASSWORD@haproxy-rishi-1:5432/rishi_hetzner_infra_template_db` |
| `DATABASE_URL_SERVER_2` | `postgresql://postgres:POSTGRES_PASSWORD@haproxy-rishi-2:5432/rishi_hetzner_infra_template_db` |

---

## Server layout after deploy

```
/home/deploy/
├── caddy/
│   ├── Caddyfile               ← hello-world AND counter blocks
│   └── docker-compose.yml
├── rishi-hetzner-infra-template-db-stack/           ← Swarm stack files (CI uploads here)
│   ├── etcd-stack.yml
│   ├── patroni-stack.yml
│   ├── haproxy-stack.yml
│   └── haproxy.cfg
└── yral-rishi-hetzner-infra-template/
    └── docker-compose.yml      ← on rishi-1 and rishi-2 only
```

Swarm services (etcd, Patroni, HAProxy) run as Swarm tasks — not in
/home/deploy directories. Check them with: `docker stack services rishi-hetzner-infra-template-db`

---

## Critical warnings

### NEVER run `docker compose down -v` on a Patroni server
The `-v` flag deletes Docker volumes. `patroni-rishi-X-data` contains ALL database data.
Always use `docker stack rm rishi-hetzner-infra-template-db` (removes stack) or `docker service update` for targeted restarts.

### The Caddyfile must include ALL service blocks
This Caddyfile has both `hello-world` and `rishi-hetzner-infra-template` blocks.
The hello-world-service repo Caddyfile ALSO needs both blocks — otherwise
pushing to that repo will overwrite Caddy config and break the counter routing.

### etcd and Patroni use --no-recreate behavior via stack deploy
Swarm stack deploy only restarts a service if its image or config changed.
If you update etcd or Patroni config manually, force an update with:
`docker service update --force rishi-hetzner-infra-template-db_etcd-rishi-1`

### Node labels must be correct before first deploy
If rishi-2's label says `server=rishi-3` by mistake, etcd-rishi-2 would
run on rishi-3 and etcd-rishi-3 would fail to schedule (no node with that label).
Verify: `ssh deploy@138.201.137.181 "docker node ls"`

### DATABASE_URL is server-specific
Unlike the hello-world service (one URL for both servers), the counter app
needs different DATABASE_URLs per server because HAProxy service names differ:
- rishi-1 app → `haproxy-rishi-1:5432`
- rishi-2 app → `haproxy-rishi-2:5432`
Use GitHub secrets `DATABASE_URL_SERVER_1` and `DATABASE_URL_SERVER_2`.
