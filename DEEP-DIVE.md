# Deep dive: how this template works (line by line)

This document explains every part of the template for someone who has never
seen the code before. No programming jargon without explanation. Read this
alongside the code and you'll understand 100% of what's happening.

---

## Part 1: What happens when a user visits the URL

When someone opens `https://rishi-hetzner-infra-template.rishi.yral.com/`
in their browser, here's EXACTLY what happens, step by step:

```
1. Browser asks DNS: "what IP is rishi-hetzner-infra-template.rishi.yral.com?"
   → Cloudflare answers with TWO IPs (rishi-1: 138.201.137.181, rishi-2: 136.243.150.84)
   → Browser picks one randomly (DNS round-robin)

2. Browser connects to that IP on port 443 (HTTPS)
   → Cloudflare's edge proxy handles the TLS encryption
   → Cloudflare forwards the request to our server

3. On the server, Caddy (a reverse proxy) receives the request
   → Caddy reads the Host header: "rishi-hetzner-infra-template.rishi.yral.com"
   → Caddy looks up its config: this domain maps to container "yral-rishi-hetzner-infra-template" on port 8000
   → Caddy forwards the request to port 8000 inside the Docker network

4. Our FastAPI app (running in a Docker container) receives: GET /
   → app/main.py's root() function runs
   → It calls get_next_count() from app/database.py

5. get_next_count() talks to PostgreSQL:
   → Gets a connection from the pool (a pre-opened set of database connections)
   → Sends SQL: UPDATE counter SET value = value + 1 WHERE id = 1 RETURNING value;
   → PostgreSQL atomically adds 1 to the counter and returns the new value (e.g., 336)
   → Connection goes back to the pool for the next request

6. root() formats the response: {"message": "Hello World Person 336"}
   → FastAPI converts this to JSON
   → Sends it back through Caddy → Cloudflare → browser
```

The whole thing takes ~50 milliseconds.

### But WHERE is the database?

The PostgreSQL database is NOT on the same server as the app. It could be
on rishi-1, rishi-2, or rishi-3 — whichever is the current "leader."

```
App on rishi-1
  ↓ connects to HAProxy (a load balancer for the database)
HAProxy on rishi-1
  ↓ checks: "which Patroni node is the leader right now?"
  ↓ answer: rishi-2 is the leader today
  ↓ routes the SQL query to rishi-2
PostgreSQL on rishi-2 (the leader)
  ↓ executes UPDATE counter...
  ↓ sends the result back
```

If the leader (rishi-2) crashes, Patroni automatically promotes rishi-1 or
rishi-3 to be the new leader within ~12 seconds. The app doesn't need to
know this happened — HAProxy automatically routes to the new leader.

---

## Part 2: The files, one by one

### `project.config` — the single source of truth

This is the MOST IMPORTANT file in the template. Every other file reads
from it. When you create a new service, you change THIS file and nothing
else.

```bash
PROJECT_NAME=rishi-hetzner-infra-template
```

**What this means:** the bare name of the project. Used everywhere:
- As the subdomain prefix (→ `rishi-hetzner-infra-template.rishi.yral.com`)
- As the suffix of every other identifier below

```bash
PROJECT_DOMAIN=rishi-hetzner-infra-template.rishi.yral.com
```

**What this means:** the full public URL. Caddy uses this to know which
requests belong to this service.

```bash
PROJECT_REPO=yral-rishi-hetzner-infra-template
```

**What this means:** the GitHub repo name AND the Docker container name.
Everything at dolr-ai gets a `yral-` prefix by convention.

```bash
POSTGRES_DB=rishi_hetzner_infra_template_db
```

**What this means:** the PostgreSQL database name. Uses underscores (not
hyphens) because PostgreSQL doesn't allow hyphens in database names.

```bash
PATRONI_SCOPE=rishi-hetzner-infra-template-cluster
```

**What this means:** a namespace for this project's database cluster inside
etcd (the coordination service). Without this, two projects sharing the
same servers would confuse each other's leader elections.

```bash
SWARM_STACK=rishi-hetzner-infra-template-db
```

**What this means:** the Docker Swarm stack name. Docker Swarm uses this
to group related containers (etcd, Patroni, HAProxy) together.

```bash
OVERLAY_NETWORK=rishi-hetzner-infra-template-db-internal
```

**What this means:** a private, encrypted network that ONLY this project's
database containers can see. It's invisible from the internet. Two projects
on the same servers cannot see each other's database traffic.

```bash
WITH_DATABASE=true
```

**What this means:** whether this service needs a database. Set to `false`
for services that don't need PostgreSQL (e.g., an ML model that just
returns predictions). When false, CI skips deploying etcd/Patroni/HAProxy.

### `servers.config` — where the servers live

```bash
SERVER_1_IP=138.201.137.181
SERVER_2_IP=136.243.150.84
SERVER_3_IP=136.243.147.225
DEPLOY_USER=deploy
SSH_KEY_PATH=~/.ssh/rishi-hetzner-ci-key
```

**Why this is separate from project.config:** these IPs are the SAME for
every dolr-ai service. project.config changes per project; servers.config
almost never changes (only when Saikat replaces a server or adds a new one).

**Why these are NOT in GitHub Secrets:** IPs and a username are not secrets.
Anyone with access to the GitHub repo can see them. Putting them in GitHub
Secrets would mean every new project repo needs to set 4 extra secrets
manually — error-prone and unnecessary.

---

### `app/main.py` — the application entry point

This is where the app starts. When Docker runs the container, it executes:
```
uvicorn main:app --host 0.0.0.0 --port 8000
```

`uvicorn` is a web server. `main:app` means "in the file `main.py`, find
the variable called `app`." That variable is a FastAPI application.

**Line by line:**

```python
import sentry_sdk
```
Imports the Sentry error tracking library. Sentry catches crashes and
sends them to apm.yral.com so you can see what went wrong.

```python
from fastapi import FastAPI, HTTPException
```
Imports FastAPI (the web framework that handles HTTP requests) and
HTTPException (a way to return error responses like 503).

```python
from database import get_next_count, check_db_health
```
Imports two functions from our `database.py` file (same `app/` directory).
- `get_next_count()` — increments the counter and returns the new value
- `check_db_health()` — checks if the database is reachable

```python
from infra import init_sentry
```
Imports the Sentry initialization function from our `infra/` package.

```python
init_sentry()
```
Calls the function. If SENTRY_DSN environment variable is set, this
wires up error tracking. If not set (like in local development), this
does nothing — it's a "no-op" (no operation).

```python
app = FastAPI()
```
Creates the web application. This is the `app` that `uvicorn` looks for.
FastAPI is a "framework" — it handles all the boring parts of a web server
(parsing HTTP, routing URLs to functions, converting Python dicts to JSON).

```python
@app.get("/")
def root():
```
This is a "decorator" + function definition. It means:
- `@app.get("/")` — "when someone sends a GET request to `/`, call this function"
- `def root():` — the function is called `root` (name doesn't matter, just descriptive)

```python
    try:
        count = get_next_count()
        return {"message": f"Hello World Person {count}"}
```
- `try:` — "try this code, and if it fails, go to the `except` block"
- `count = get_next_count()` — calls our database function, gets back a number (e.g., 336)
- `return {"message": f"Hello World Person {count}"}` — returns a Python dict.
  FastAPI automatically converts this to JSON: `{"message": "Hello World Person 336"}`
- The `f"..."` syntax means "format string" — `{count}` gets replaced with the actual number

```python
    except Exception as exc:
        sentry_sdk.capture_exception(exc)
        raise HTTPException(status_code=503, detail="Database unavailable") from exc
```
- If `get_next_count()` fails (database down, network error, etc.):
  - `sentry_sdk.capture_exception(exc)` — sends the error to Sentry for tracking
  - `raise HTTPException(status_code=503, ...)` — returns HTTP 503 (Service Unavailable)
    to the browser with the message "Database unavailable"

```python
@app.get("/health")
def health():
```
The health check endpoint. Docker's healthcheck, CI's verify step, and
Uptime Kuma all hit this every few seconds.

```python
    if not check_db_health():
        raise HTTPException(status_code=503, detail={...})
    return {"status": "OK", "database": "reachable"}
```
- Calls `check_db_health()` which queries the counter table
- If the database is down → returns 503
- If healthy → returns 200 with `{"status": "OK", "database": "reachable"}`

---

### `app/database.py` — how the app talks to PostgreSQL

This file manages the connection between the Python app and the PostgreSQL
database. It handles three hard problems:
1. **Connection pooling** — keeping a set of pre-opened connections so each
   request doesn't need to open a new one (slow)
2. **Failover recovery** — detecting when a connection is broken (leader
   changed, network blip) and automatically retrying
3. **Security** — reading the database password from a file (not an
   environment variable) so it's never visible in `docker inspect`

**Key concept: connection pool**

A "connection pool" is like a shared parking lot of database connections.
Instead of opening a new connection for every web request (takes ~50ms each),
we keep 2-10 connections permanently open. When a request needs the database:
1. "Check out" a connection from the pool (instant)
2. Run the SQL query
3. "Return" the connection to the pool

This makes the app much faster under load.

```python
_pool = None  # starts as None (no pool yet)
```

The pool is created LAZILY (not when the file loads, but when the first
request comes in). Why?

**Why lazy initialization matters:**

When the Docker container starts, Python imports all files. If `database.py`
tried to connect to the database at import time and the database wasn't
ready yet (Patroni still bootstrapping), the entire app would crash before
it even started. With lazy init, the app starts fine, and the first web
request triggers the pool creation — by which time the database is usually
ready. If it's still not ready, the pool retries 5 times with 2-second waits.

**The retry logic:**

```python
def _execute_with_retry(operation, max_attempts: int = 3):
```

This function wraps every database operation with retry logic. It catches
three types of errors:

1. **Dead connection** (`OperationalError`) — the connection was open but
   the network path died (server crash, timeout). Solution: throw away
   the dead connection, get a fresh one from the pool.

2. **Read-only error** (`ReadOnlySqlTransaction`) — after a Patroni
   failover, the app's pooled connection might still point to the OLD
   leader (now a read-only replica). Replicas accept SELECT but reject
   UPDATE. Solution: throw away the connection, get a fresh one (which
   HAProxy routes to the NEW leader).

3. **Admin shutdown** — Patroni restarting PostgreSQL. Same fix: retry.

If the operation fails 3 times in a row, it gives up and raises the error
back to main.py, which returns 503 to the user.

**The atomic counter:**

```python
cur.execute("UPDATE counter SET value = value + 1 WHERE id = 1 RETURNING value;")
```

This is ONE SQL statement that does TWO things atomically:
1. Adds 1 to the counter
2. Returns the new value

"Atomically" means PostgreSQL treats this as a single indivisible step.
Even if 1000 users hit the URL at the exact same time, each one gets a
unique sequential number. No race conditions, no duplicates.

**Why NOT two statements?**

```sql
-- WRONG (two steps = race condition):
SELECT value FROM counter;        -- reads 42
-- another request reads 42 here too!
UPDATE counter SET value = 43;    -- both write 43 — we lost a count!

-- RIGHT (one atomic step):
UPDATE counter SET value = value + 1 RETURNING value;  -- always correct
```

---

### `Dockerfile` — how the Docker image is built

```dockerfile
FROM python:3.12-slim
```
Start from an official Python 3.12 image (a minimal Linux with Python
pre-installed). "slim" means it doesn't include build tools we don't need.

```dockerfile
RUN groupadd --system --gid 1001 appuser && \
    useradd  --system --uid 1001 --gid appuser --create-home --shell /usr/sbin/nologin appuser
```
Create a non-root user called `appuser`. The app runs as this user (not as
root) so that if an attacker finds a bug in our code, they get limited
permissions — they can't modify system files or escape the container.

```dockerfile
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
```
Install Python dependencies (FastAPI, Uvicorn, Sentry, psycopg2). The
`--no-cache-dir` flag saves ~50MB by not keeping pip's download cache.

```dockerfile
COPY --chown=appuser:appuser app/ .
COPY --chown=appuser:appuser infra/ ./infra/
```
Copy our application code into the image. `--chown=appuser:appuser` makes
sure the files are owned by our non-root user (not root).

```dockerfile
USER appuser
```
Switch to the non-root user. Everything after this line runs as `appuser`.

```dockerfile
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```
The command that runs when the container starts. It starts the Uvicorn web
server, which loads our FastAPI app from `main.py` and listens on port 8000.

---

### `docker-compose.yml` — how the app container is configured

This file tells Docker Compose HOW to run the app container on each server.
It's not a Docker Swarm stack file (that's for the database tier). The app
runs as a regular Docker Compose service.

Key sections:

```yaml
image: ${IMAGE_REPO}:${IMAGE_TAG:-latest}
```
Which Docker image to run. `${IMAGE_REPO}` comes from project.config
(e.g., `ghcr.io/dolr-ai/yral-rishi-hetzner-infra-template`). `${IMAGE_TAG}`
is the git SHA of the commit (e.g., `c54429a`). This means every deploy
uses a specific, immutable image — you can always roll back to an older one.

```yaml
restart: always
```
If the container crashes, Docker restarts it automatically. "always" means
even after a SIGKILL (not just graceful shutdown).

```yaml
deploy:
  resources:
    limits:
      memory: 512M
      cpus: '1.0'
```
Resource limits. The container can't use more than 512MB of RAM or 1 CPU
core. This prevents a single buggy service from killing the entire server.

```yaml
networks:
  - web
  - db-internal
```
The container joins two Docker networks:
- `web` — a local network shared with Caddy (the reverse proxy). This is
  how Caddy forwards requests to the app.
- `db-internal` — the Swarm overlay network shared with HAProxy. This is
  how the app reaches the database.

```yaml
secrets:
  - database_url
```
Mounts the file `./secrets/database_url` inside the container at
`/run/secrets/database_url`. The app reads the database password from this
file instead of from an environment variable — so it's never visible in
`docker inspect`.

```yaml
healthcheck:
  test:
    - CMD
    - python
    - -c
    - "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8000/health',timeout=5).status==200 else 1)"
```
Docker runs this command every 5 seconds. It hits the `/health` endpoint.
If it returns 200, the container is "healthy." If it fails 3 times in a
row (after the 30-second start_period), the container is "unhealthy."

The canary deploy script watches this status to decide if the new image
is safe to keep or needs to be rolled back.

---

### `migrations/001_initial.sql` — the database schema

```sql
CREATE TABLE IF NOT EXISTS counter (
    id    INTEGER PRIMARY KEY,
    value BIGINT NOT NULL DEFAULT 0
);
```

Creates the `counter` table with two columns:
- `id` — an integer that identifies each counter. PRIMARY KEY means each
  row must have a unique id.
- `value` — a BIGINT (big integer, up to 9.2 quintillion). NOT NULL means
  it can never be empty. DEFAULT 0 means new rows start at 0.

`IF NOT EXISTS` means "don't crash if the table already exists" — this
makes the migration safe to re-run.

```sql
INSERT INTO counter (id, value) VALUES (1, 0) ON CONFLICT (id) DO NOTHING;
```

Inserts the initial row: counter #1, starting at 0. `ON CONFLICT DO NOTHING`
means "if row with id=1 already exists, do nothing" — also safe to re-run.

---

## Visual diagrams

### Diagram 1: What happens when a user visits the URL

```
    USER'S BROWSER
         |
         | 1. "What IP is rishi-hetzner-infra-template.rishi.yral.com?"
         v
    CLOUDFLARE DNS
         |
         | 2. "Here are TWO IPs: 138.201.137.181 and 136.243.150.84"
         |    (browser picks one randomly)
         v
    CLOUDFLARE EDGE (HTTPS termination)
         |
         | 3. Forwards request to the chosen server
         v
   +-----------+                              +-----------+
   |  RISHI-1  |       (or, randomly)         |  RISHI-2  |
   |           |                              |           |
   |  Caddy    |                              |  Caddy    |
   |    |      |                              |    |      |
   |    v      |                              |    v      |
   |  App      |                              |  App      |
   |  (FastAPI)|                              |  (FastAPI)|
   |    |      |                              |    |      |
   |    v      |                              |    v      |
   |  HAProxy -+----- overlay network --------+- HAProxy  |
   |    |      |     (private, encrypted)     |    |      |
   +----|------+                              +----|------+
        |                                          |
        +---------- routes to LEADER --------------+
                         |
              +----------+----------+
              |          |          |
         +---------+ +--------+ +--------+
         | rishi-1 | | rishi-2| | rishi-3|
         | Patroni | | Patroni| | Patroni|
         |         | | LEADER | |        |
         | replica | |        | | replica|
         +---------+ +--------+ +--------+
              |          |           |
              +--- streaming replication ---+
```

### Diagram 2: What happens when you push code (CI/CD pipeline)

```
    YOU: git push origin main
         |
         v
    GITHUB ACTIONS starts the workflow
         |
         +---> Job 0: READ CONFIG
         |         reads project.config → WITH_DATABASE flag
         |
         +---> Job 1: GITLEAKS (parallel)     Job 2: TESTS (parallel)
         |         scan git history              pytest + integrity check
         |         for leaked passwords          for broken configs
         |              |                             |
         |              +-------- both pass ----------+
         |                           |
         +---> Job 3: BUILD + PUSH
         |         docker build → 3 images:
         |           app image     (your Python code)
         |           patroni image (PostgreSQL + Patroni)
         |           backup image  (pg_dump + mc)
         |         push all 3 to GHCR
         |         Trivy scan → CRITICAL CVE = FAIL
         |                           |
         +---> Job 4: DEPLOY DB STACK (if WITH_DATABASE=true)
         |         SSH to rishi-1 (Swarm manager)
         |         docker stack deploy:
         |           3x etcd    (leader election)
         |           3x Patroni (PostgreSQL HA)
         |           2x HAProxy (DB load balancer)
         |                           |
         +---> Job 5: DEPLOY APP (canary pattern)
                  |
                  +---> RISHI-1 (canary — goes first)
                  |       1. SCP files to server
                  |       2. Run SQL MIGRATIONS (before new code!)
                  |       3. docker compose up -d (new image)
                  |       4. Wait for healthcheck = "healthy"
                  |       5. Curl /health through Caddy
                  |       6. If UNHEALTHY → auto-rollback!
                  |       7. If HEALTHY → record tag, update Caddy
                  |              |
                  |         (only if rishi-1 FULLY succeeded)
                  |              |
                  +---> RISHI-2 (same steps)
                          |
                     DEPLOY COMPLETE
```

### Diagram 3: What happens during a database failover

```
    BEFORE: rishi-2 is the leader, rishi-1 and rishi-3 are replicas

    rishi-1 (replica)  ←── streaming ──→  rishi-2 (LEADER)  ←── streaming ──→  rishi-3 (replica)
                                              |
                                          CRASH! 💥
                                              |
    STEP 1: etcd detects rishi-2 is gone (within 30 seconds)
    STEP 2: Patroni on rishi-1 and rishi-3 VOTE (quorum: 2 of 3 agree)
    STEP 3: rishi-1 is PROMOTED to leader (has the most recent data)
    STEP 4: HAProxy detects new leader via /master health check (~3 seconds)
    STEP 5: App's connection pool retries → HAProxy routes to rishi-1 → success

    AFTER: rishi-1 is the new leader

    rishi-1 (NEW LEADER)  ←── streaming ──→  rishi-3 (replica)

    rishi-2 comes back → Patroni re-joins as replica → streams from rishi-1
```

### Diagram 4: How migrations work (expand-contract)

```
    DEPLOY 1: ADD NEW COLUMN (expand — safe)

    ┌──────────────────────────────────────────────────────┐
    │ BEFORE                                               │
    │   counter table: [id, value]                         │
    │   app code: uses id, value                           │
    │   rishi-1: OLD code    rishi-2: OLD code             │
    └──────────────────────────────────────────────────────┘
                              |
                    migration runs on rishi-1
                    ALTER TABLE counter ADD COLUMN email;
                              |
    ┌──────────────────────────────────────────────────────┐
    │ DURING DEPLOY                                        │
    │   counter table: [id, value, email]  ← expanded!     │
    │   rishi-1: OLD code    rishi-2: OLD code             │
    │   (old code doesn't use email — that's fine)         │
    └──────────────────────────────────────────────────────┘
                              |
                    new app image starts on rishi-1
                              |
    ┌──────────────────────────────────────────────────────┐
    │ AFTER                                                │
    │   counter table: [id, value, email]                  │
    │   rishi-1: NEW code (uses email)                     │
    │   rishi-2: NEW code (uses email)                     │
    │   ZERO DOWNTIME ✓                                    │
    └──────────────────────────────────────────────────────┘


    DEPLOY 2: REMOVE OLD COLUMN (contract — after all servers have new code)

    migration: ALTER TABLE counter DROP COLUMN old_name;
    (only safe because NO code references old_name anymore)
```

### Diagram 5: Backup and restore flow

```
    DAILY (3:00 AM UTC via GitHub Actions):

    GitHub Actions
         |
         | SSH to rishi-1
         v
    docker run backup-container --network overlay
         |
         | pg_dump via HAProxy → leader → SQL dump
         v
    gzip -9 (compress ~10x)
         |
         | mc cp (MinIO Client upload)
         v
    Hetzner Object Storage
    s3://rishi-yral/
      └── yral-my-service/        ← per-service prefix (isolated!)
            ├── daily/
            │     ├── 2026-04-12_030000.sql.gz
            │     ├── 2026-04-11_030000.sql.gz   ← keep last 7
            │     └── ...
            └── weekly/
                  ├── 2026-04-06.sql.gz          ← keep last 4
                  └── ...


    RESTORE (manual, when needed):

    bash scripts/restore-from-backup.sh --latest
         |
         | 1. Download backup from S3
         | 2. DROP DATABASE + CREATE DATABASE
         | 3. Restore from dump (psql < dump.sql.gz)
         | 4. Re-run pending migrations (auto!)
         | 5. Restart app containers (clear pool)
         v
    Service back online at the backup's point in time
```

### Diagram 6: Project isolation (why services can't interfere)

```
    SAME 3 SERVERS, but every layer is isolated:

    ┌─────────────────────────────────────────────────────────┐
    │                     rishi-1 / rishi-2 / rishi-3         │
    │                                                         │
    │  SERVICE A (my-service)          SERVICE B (nsfw-svc)   │
    │  ├── Caddy snippet:              ├── Caddy snippet:     │
    │  │   yral-my-service.caddy       │   yral-nsfw-svc.caddy│
    │  ├── App container:              ├── App container:      │
    │  │   yral-my-service             │   yral-nsfw-svc       │
    │  ├── Swarm stack:                ├── Swarm stack:        │
    │  │   my-service-db               │   nsfw-svc-db         │
    │  ├── Overlay network:            ├── Overlay network:    │
    │  │   my-service-db-internal      │   nsfw-svc-db-internal│
    │  │   (CANNOT see B's network)    │   (CANNOT see A's)   │
    │  ├── Secrets:                    ├── Secrets:            │
    │  │   my-service-db_pg_pass       │   nsfw-svc-db_pg_pass │
    │  ├── Database:                   ├── Database:           │
    │  │   my_service_db               │   nsfw_svc_db         │
    │  ├── etcd scope:                 ├── etcd scope:         │
    │  │   my-service-cluster          │   nsfw-svc-cluster    │
    │  └── S3 backup prefix:           └── S3 backup prefix:  │
    │      rishi-yral/yral-my-service/     rishi-yral/yral-nsfw│
    │                                                         │
    │  A deploys → B is NOT affected.                         │
    │  A crashes → B keeps serving.                           │
    │  A's backup → only A's data.                            │
    └─────────────────────────────────────────────────────────┘
```

## Part 3: What happens when you push code

When you `git push` to the `main` branch, GitHub Actions runs the CI/CD
pipeline defined in `.github/workflows/deploy.yml`. Here's the full flow:

```
You: git push origin main
  ↓
GitHub detects the push, starts the workflow
  ↓
Job 0: "config" — reads project.config to get WITH_DATABASE flag
  ↓
Job 1: "gitleaks" — scans ALL git history for accidentally committed passwords
  ↓ (parallel with)
Job 2: "test" — installs Python deps, runs pytest, runs template integrity check
  ↓ (both must pass)
Job 3: "build-and-push" — builds 3 Docker images:
  a. App image (from Dockerfile)
  b. Patroni image (from patroni/Dockerfile) — only if WITH_DATABASE=true
  c. Backup image (from backup/Dockerfile) — only if WITH_DATABASE=true
  → pushes all 3 to GHCR (GitHub Container Registry)
  → runs Trivy vulnerability scanner on the app image (CRITICAL = fail)
  ↓
Job 4: "deploy-db-stack" — only if WITH_DATABASE=true
  → SSHes into rishi-1 (the Swarm manager)
  → creates Docker Swarm secrets (postgres_password, replication_password)
  → docker stack deploy (etcd + Patroni + HAProxy)
  ↓
Job 5: "deploy-app" — CANARY pattern
  → RISHI-1 FIRST (canary):
    1. SCP files to rishi-1 (compose, migrations, caddy snippet, scripts)
    2. Run SQL migrations (BEFORE the new app starts!)
    3. docker compose up -d (start the new app image)
    4. Wait for Docker healthcheck to report "healthy"
    5. Curl the /health endpoint through Caddy
    6. If UNHEALTHY → auto-rollback to the last known good image
    7. If HEALTHY → record the new image tag, update Caddy config
  → RISHI-2 ONLY IF RISHI-1 SUCCEEDED
    (same steps; if rishi-1 failed, rishi-2 is never touched)
```

**Why this order matters:**

If a bad image is deployed to BOTH servers at the same time, the service
is completely down. The canary pattern deploys to rishi-1 first. If it
fails, rishi-2 still has the old (working) image. Cloudflare routes 50%
of traffic to rishi-2 — so the service stays up while you fix the bug.

---

## Part 4: Why these architectural decisions

### Why 3 servers for the database?

With 2 servers: if rishi-1 loses contact with rishi-2, neither can safely
decide if the other is dead or just has a network blip. If both promote
themselves to leader, you get "split-brain" — two copies of the database
diverge, corrupting data permanently.

With 3 servers: they VOTE. 2 out of 3 must agree that a node is dead
before promoting a new leader. This is called "quorum." A network split
can't give both sides a majority simultaneously.

### Why HAProxy instead of connecting directly to PostgreSQL?

The app doesn't know (or care) which server is the current leader. HAProxy
checks every 3 seconds by hitting Patroni's `/master` endpoint on each
node. Whichever responds "I am the leader" gets the traffic. When a
failover happens, HAProxy detects the new leader within 3 seconds and
redirects all connections — the app doesn't need to restart or reconfigure.

### Why Docker Swarm instead of Kubernetes?

Kubernetes is the industry standard for container orchestration but it
requires 3+ dedicated manager nodes and significant operational complexity.
For a 3-server cluster running a handful of services, Swarm is dramatically
simpler: it's built into Docker, needs no extra installation, and does
exactly what we need (overlay networks, service placement, rolling updates,
secret management). If dolr-ai grows to 20+ servers or 50+ services,
migrating to Kubernetes would make sense.

### Why Caddy instead of Nginx?

Caddy automatically manages TLS certificates (HTTPS) with zero
configuration. Nginx requires manual certificate management or a separate
tool like certbot. Since we have Cloudflare in front (which handles the
public TLS), Caddy's `tls internal` mode gives us encrypted connections
between Cloudflare and the server with no setup.

### Why per-project overlay networks?

Each project gets its own encrypted network (e.g.,
`rishi-hetzner-infra-template-db-internal`). This means:
- Project A's app cannot reach Project B's database
- Project A's Patroni cannot see Project B's Patroni
- A security breach in one service cannot pivot to another

Without per-project networks, all services would share a single network
and any service's HAProxy could route to any other service's PostgreSQL.

### Why `project.config` instead of hardcoded values?

The original template had the project name hardcoded in ~50 files. To
create a new service, you had to find-and-replace across the entire repo.
Miss one occurrence → cryptic deploy failure.

Now every file reads from `project.config` via `${VAR}` interpolation.
To create a new service: edit ONE file, everything else follows. This is
the "single source of truth" principle — there's exactly one place where
the project name is defined.

### Why migrations run BEFORE the new app starts?

If migrations ran AFTER the app starts:
1. New code starts → expects a column that doesn't exist yet → crashes
2. During the 30 seconds between "app starts" and "migration runs,"
   users see 503 errors

By running migrations FIRST (while the old app is still serving traffic):
1. Old app keeps running (doesn't use the new column)
2. Migration adds the new column
3. New app starts and finds everything it needs

This is the "expand-contract" pattern. Additive changes (new columns,
new tables) always go in the migration BEFORE the code that uses them.

### Why daily backups to object storage?

PostgreSQL has 3-way replication (leader + 2 replicas). But replication
protects against SERVER failure, not DATA corruption. If someone runs
`DELETE FROM counter` on the leader, that DELETE replicates to all 3
servers — all copies are equally corrupted.

Only an EXTERNAL backup (stored outside the cluster) protects against data
corruption, accidental deletes, or ransomware. The daily pg_dump to Hetzner
Object Storage is that external backup. RPO (recovery point objective) is
24 hours — you can lose at most 1 day of data.

### Why non-root containers?

If an attacker finds a bug in FastAPI or any Python dependency, they can
execute code inside the container. If the container runs as root, they
have full access to the container filesystem, can modify binaries, and
potentially escape to the host.

With a non-root user (appuser, UID 1001), the attacker can only read
application code and write to /tmp. They can't modify binaries, install
packages, or access Docker sockets. It's not bulletproof, but it raises
the bar from "trivial exploit" to "needs a kernel privilege escalation."

---

## Part 5: How to create a new service

```bash
bash scripts/new-service.sh --name my-service
```

What this single command does:
1. Validates your name (≤39 chars, lowercase, alphanumeric + hyphens)
2. Copies the entire template to `~/Claude Projects/yral-my-service/`
3. Runs `init-from-template.sh` which edits ONLY project.config
   (replaces `rishi-hetzner-infra-template` with `my-service` everywhere)
4. Generates strong random passwords (POSTGRES_PASSWORD, REPLICATION_PASSWORD)
5. Composes the DATABASE_URL strings for both servers
6. Creates a GitHub repo: `dolr-ai/yral-my-service`
7. Pushes the initial commit
8. Sets all 5 GitHub Secrets automatically
9. Watches the first CI run to completion
10. Verifies the /health endpoint responds 200

After this, you edit `app/main.py` and `app/database.py` with your
business logic, push, and CI deploys it.

---

## Glossary

| Term | Plain English |
|---|---|
| **API** | A set of URLs that a program can call to get or send data |
| **CI/CD** | Continuous Integration / Continuous Deployment — code that automatically tests and deploys your changes when you push |
| **Container** | A lightweight, isolated box that runs your app with all its dependencies |
| **DNS** | Domain Name System — translates domain names (google.com) to IP addresses (142.250.80.14) |
| **Docker** | Software that runs containers |
| **Docker Compose** | A tool that defines how to run multiple containers together on ONE server |
| **Docker Swarm** | A tool that runs containers across MULTIPLE servers |
| **etcd** | A distributed key-value store used by Patroni for leader election |
| **FastAPI** | A Python web framework for building APIs |
| **GHCR** | GitHub Container Registry — where Docker images are stored |
| **HAProxy** | A load balancer that routes database connections to the current leader |
| **Healthcheck** | A periodic check that verifies a service is working |
| **JSON** | JavaScript Object Notation — a text format for structured data: `{"key": "value"}` |
| **Leader** | The PostgreSQL server that accepts write operations (INSERT, UPDATE, DELETE) |
| **Migration** | A SQL file that changes the database schema (adds tables, columns, etc.) |
| **Overlay network** | A virtual network that spans multiple servers (encrypted, private) |
| **Patroni** | Software that manages PostgreSQL replication and automatic failover |
| **pg_dump** | A PostgreSQL tool that exports the entire database to a file |
| **Pool** | A set of pre-opened database connections shared across requests |
| **Quorum** | A majority vote (2 out of 3) needed to make a decision |
| **Replica** | A PostgreSQL server that maintains a copy of the leader's data (read-only) |
| **Reverse proxy** | A server (Caddy) that sits between the internet and your app, forwarding requests |
| **S3** | Amazon's object storage protocol — also used by Hetzner, Cloudflare R2, Backblaze B2 |
| **Secret** | A password or key that must not be visible in code or logs |
| **SSH** | Secure Shell — encrypted remote access to servers |
| **Swarm stack** | A group of Docker services deployed together (etcd + Patroni + HAProxy) |
| **TLS** | Transport Layer Security — encryption for HTTPS connections |
| **Uvicorn** | An ASGI server that runs FastAPI applications |
| **WAL** | Write-Ahead Log — PostgreSQL's transaction log used for replication |
