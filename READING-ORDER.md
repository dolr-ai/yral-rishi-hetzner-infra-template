# How to read this codebase (start here)

Read the files in this order. Each file builds on what you learned from
the previous one. Don't skip ahead — each step matters.

---

## Step 1: Understand the big picture first

```
📖 Read: DEEP-DIVE.md
```

This explains EVERYTHING visually — what happens when a user visits the
URL, how code gets deployed, how the database works, why every
architectural decision was made. Has 6 diagrams and a glossary. Read
this FIRST before opening any code file.

---

## Step 2: The two config files (the foundation)

```
📖 Read: project.config     ← what makes each service unique
📖 Read: servers.config      ← where the servers are
```

Every other file reads from these. Understanding these two files means
you understand the "inputs" to the entire system.

---

## Step 3: The application code (what the user sees)

Read these in order — they're the core of what the app DOES:

```
📖 Read: app/main.py          ← the web routes (GET /, GET /health)
📖 Read: app/database.py      ← how the app talks to PostgreSQL
📖 Read: requirements.txt     ← what Python libraries are used
```

After reading these 3 files, you understand the ENTIRE business logic.

---

## Step 4: How the app is packaged (Docker)

```
📖 Read: Dockerfile            ← how the app image is built
📖 Read: docker-compose.yml    ← how the app container is configured
📖 Read: .dockerignore         ← what's excluded from the build
```

After these, you understand how code becomes a running container.

---

## Step 5: How the database works (HA tier)

Read in this order — each builds on the previous:

```
📖 Read: migrations/001_initial.sql    ← the database schema (tables)
📖 Read: patroni/patroni.yml          ← how Patroni manages PostgreSQL
📖 Read: patroni/entrypoint.sh        ← how the container starts
📖 Read: patroni/post_init.sh         ← how the database is initialized
📖 Read: patroni/init.sql             ← the migration tracking table
📖 Read: patroni/Dockerfile           ← how the Patroni image is built
📖 Read: patroni/stack.yml            ← how 3 Patroni containers are deployed
📖 Read: etcd/stack.yml               ← how 3 etcd containers are deployed
📖 Read: haproxy/haproxy.cfg          ← how HAProxy routes to the leader
📖 Read: haproxy/stack.yml            ← how 2 HAProxy containers are deployed
```

After these, you understand the entire database HA architecture.

---

## Step 6: How deploys work (CI/CD)

```
📖 Read: scripts/ci/deploy-app.sh       ← canary deploy with auto-rollback
📖 Read: scripts/ci/deploy-db-stack.sh   ← how the DB stack is deployed
📖 Read: scripts/ci/run-migrations.sh    ← how schema changes are applied
📖 Read: .github/workflows/deploy.yml    ← the full CI/CD pipeline
```

After these, you understand what happens when you `git push`.

---

## Step 7: Backups and recovery

```
📖 Read: backup/backup.sh               ← how pg_dump + S3 upload works
📖 Read: backup/Dockerfile              ← the backup container image
📖 Read: .github/workflows/backup.yml   ← the daily backup schedule
📖 Read: scripts/restore-from-backup.sh ← how to restore from S3
```

After these, you understand the data protection story.

---

## Step 8: How to create a new service

```
📖 Read: scripts/init-from-template.sh  ← how project.config is renamed
📖 Read: scripts/new-service.sh         ← the one-command bootstrap
📖 Read: scripts/teardown-service.sh    ← how to remove a service
📖 Read: TEMPLATE.md                    ← the step-by-step guide
```

After these, you can create your own service from the template.

---

## Step 9: Security and integrations

```
📖 Read: SECURITY.md                    ← threat model + defenses
📖 Read: caddy/snippet.caddy.template   ← security headers + reverse proxy
📖 Read: infra/sentry.py                ← error tracking
📖 Read: infra/vault.py                 ← secret management
📖 Read: infra/uptime_kuma.py           ← uptime monitoring
📖 Read: .gitleaks.toml                 ← secret scanning config
📖 Read: .github/dependabot.yml         ← dependency update automation
```

---

## Step 10: Server management (rarely needed)

```
📖 Read: scripts/swarm-setup.sh          ← one-time Swarm cluster setup
📖 Read: scripts/add-server.sh           ← adding a new server
📖 Read: scripts/rotate-secrets.sh       ← changing passwords
📖 Read: scripts/strip-database.sh       ← converting to stateless
📖 Read: scripts/manual-deploy.sh        ← emergency deploy without CI
📖 Read: .github/workflows/infra-health.yml ← automated health monitoring
```

---

## Quick reference: what's in each directory

```
yral-rishi-hetzner-infra-template/
│
├── app/                    ← YOUR business logic (replace per project)
│   ├── main.py            ← web routes
│   └── database.py        ← database queries
│
├── infra/                  ← reusable integration helpers
│   ├── sentry.py          ← error tracking
│   ├── vault.py           ← secret management
│   └── uptime_kuma.py     ← uptime monitoring
│
├── migrations/             ← database schema changes (numbered SQL files)
│   └── 001_initial.sql    ← the first migration
│
├── patroni/                ← PostgreSQL HA (high availability)
│   ├── Dockerfile         ← Patroni + PostgreSQL image
│   ├── patroni.yml        ← Patroni configuration
│   ├── stack.yml          ← 3-node Swarm deployment
│   ├── entrypoint.sh      ← container startup (secrets + lock cleanup)
│   ├── post_init.sh       ← one-time database initialization
│   └── init.sql           ← migration tracking table
│
├── etcd/                   ← leader election coordination
│   └── stack.yml          ← 3-node etcd Swarm deployment
│
├── haproxy/                ← database connection routing
│   ├── haproxy.cfg        ← routing rules + health checks
│   └── stack.yml          ← 2-node HAProxy Swarm deployment
│
├── backup/                 ← database backup to S3
│   ├── Dockerfile         ← backup container (pg_dump + mc)
│   └── backup.sh          ← the backup script
│
├── caddy/                  ← reverse proxy (HTTPS)
│   └── snippet.caddy.template  ← per-project Caddy config
│
├── local/                  ← local development (runs on your Mac)
│   ├── setup.sh           ← one-command local stack
│   ├── teardown.sh        ← stop + cleanup
│   └── docker-compose.yml ← local version of the full stack
│
├── scripts/                ← operational tools
│   ├── new-service.sh     ← create a new service (one command)
│   ├── teardown-service.sh ← remove a service completely
│   ├── add-server.sh      ← add a new Hetzner server
│   ├── swarm-setup.sh     ← one-time cluster initialization
│   ├── manual-deploy.sh   ← emergency deploy (no CI)
│   ├── rotate-secrets.sh  ← change database passwords
│   ├── strip-database.sh  ← convert to stateless service
│   ├── restore-from-backup.sh ← restore from S3 backup
│   ├── init-from-template.sh  ← rename project.config
│   └── ci/                ← scripts that run ON the servers during deploy
│       ├── deploy-app.sh  ← canary deploy + auto-rollback
│       ├── deploy-db-stack.sh ← deploy etcd + Patroni + HAProxy
│       └── run-migrations.sh  ← apply pending SQL migrations
│
├── tests/                  ← automated tests
│   ├── test_app.py        ← unit tests for the app
│   ├── test_infra.py      ← unit tests for infra helpers
│   ├── test_template_integrity.sh ← config validation
│   └── integration/       ← live failover + parity tests (manual)
│
├── .github/                ← CI/CD automation
│   ├── workflows/
│   │   ├── deploy.yml     ← the main deploy pipeline
│   │   ├── backup.yml     ← daily backup schedule
│   │   └── infra-health.yml ← 5-minute health checks
│   └── dependabot.yml     ← weekly dependency updates
│
├── project.config          ← THE source of truth (project name, domain, etc.)
├── servers.config          ← server IPs + deploy user
├── Dockerfile              ← app container image
├── docker-compose.yml      ← app container configuration
├── requirements.txt        ← Python dependencies
├── requirements-dev.txt    ← test dependencies
├── .gitignore              ← files git should ignore
├── .dockerignore           ← files Docker should ignore
├── .gitleaks.toml          ← secret scanning rules
│
├── DEEP-DIVE.md            ← start here (visual diagrams + explanations)
├── READING-ORDER.md        ← this file (what order to read)
├── CLAUDE.md               ← architecture reference
├── TEMPLATE.md             ← how to create a new service
├── MIGRATIONS.md           ← how to change the database schema
├── SECURITY.md             ← security model + threat analysis
├── INTEGRATIONS.md         ← Sentry, Vault, Uptime Kuma, Beszel
└── README.md               ← project overview
```
