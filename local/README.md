# Local development — full stack on your laptop

This directory runs the **entire production stack** (3 etcd nodes,
3 Patroni+PostgreSQL nodes, HAProxy, app) on a single Mac via
docker-compose. No Swarm, no remote servers, no CI cycle.

## Quick start

```bash
bash local/setup.sh
```

This will:
1. Generate random passwords into `local/secrets/` (gitignored)
2. Build the counter app and Patroni images locally
3. Start all 8 containers
4. Wait for the cluster to converge (~45s on first run)
5. Print the URLs to test

When ready, hit it:
```bash
curl http://localhost:8080/
# {"message":"Hello World Person 1"}

curl http://localhost:8080/
# {"message":"Hello World Person 2"}
```

## Tear it down

```bash
bash local/teardown.sh
```

This stops all containers, **deletes data volumes**, and removes the
local secrets. Next `setup.sh` starts from a fresh bootstrap.

## Why does this exist?

Production deploys via GitHub Actions take 3-5 minutes per cycle.
For iteration on Patroni configs, app code, or HAProxy rules, that's
death. With this local setup the iteration is:

```bash
# edit something
docker compose -f local/docker-compose.yml up -d --build app  # 5 seconds
curl http://localhost:8080/
```

## How it mirrors production

| Production (Docker Swarm, 3 servers) | Local (this directory) |
|---|---|
| 3 etcd nodes pinned to rishi-1/2/3 | 3 etcd containers on bridge network |
| 3 Patroni nodes pinned to rishi-1/2/3 | 3 Patroni containers, same names |
| HAProxy on rishi-1 + rishi-2 (Swarm) | 1 HAProxy container |
| App on rishi-1 + rishi-2 (compose) | 1 app container exposing :8080 |
| Caddy + Cloudflare for HTTPS | Skipped (use http://localhost:8080) |
| Docker Swarm secrets | docker-compose `secrets:` (same `/run/secrets/` paths) |
| `db-internal` overlay network | `local-net` bridge network |
| Image pulled from GHCR | Built locally from same Dockerfile |

The Patroni image, `patroni.yml`, `post_init.sh`, `init.sql`, and
`haproxy.cfg` are all the **production files unchanged** — local
just wires them up differently.

## Inspect / debug

```bash
# Patroni cluster status
docker exec patroni-rishi-1 patronictl -c /etc/patroni.yml list

# Logs for all services
docker compose -f local/docker-compose.yml logs -f

# Logs for one service
docker compose -f local/docker-compose.yml logs -f patroni-rishi-1

# Connect to the leader as postgres
docker exec -it patroni-rishi-1 psql -h 127.0.0.1 -U postgres -d rishi_offline_testing_db

# Show the secrets being used
ls -la local/secrets/
cat local/secrets/postgres_password
```

## Test failover locally

```bash
# Find the current leader
docker exec patroni-rishi-1 patronictl -c /etc/patroni.yml list

# Kill the leader (replace with the actual leader name)
docker stop patroni-rishi-2

# Wait ~30 seconds, then check — a different node should be leader
sleep 35
docker exec patroni-rishi-1 patronictl -c /etc/patroni.yml list

# Counter should keep working through the failover
curl http://localhost:8080/
curl http://localhost:8080/

# Bring the killed node back
docker start patroni-rishi-2
```

## Limitations

- **No Caddy / TLS** — local skips the HTTPS layer entirely
- **No Sentry** — `SENTRY_DSN` is empty in the local compose
- **No Cloudflare** — single localhost endpoint
- **One host** — you can simulate failover by stopping a container, but
  you can't simulate "rishi-1 the physical server is gone" the same way
  Docker Swarm would handle it across real machines
