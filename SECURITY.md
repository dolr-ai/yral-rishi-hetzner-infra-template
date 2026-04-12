# Security model

This template ships with security defaults that every dolr-ai service inherits.
Read this before changing any of them.

## Threat model

| Threat | Defense |
|---|---|
| Stolen GHCR / GitHub token | GHCR push uses `${{ secrets.GITHUB_TOKEN }}` (job-scoped, auto-expires) |
| Database password in `docker inspect` | Mounted as Docker secret file at `/run/secrets/database_url` |
| Patroni passwords in env vars | Mounted as Swarm secrets, namespaced per stack |
| Secrets committed to git | gitleaks scan in CI on every push (`gitleaks` job) |
| Vulnerable base image | Trivy scan in CI after build (CRITICAL/HIGH only, report-mode) |
| Cross-project lateral movement | Per-project overlay network, per-project Swarm secrets, per-project Caddy snippet |
| Public exposure of Postgres | `db-internal` is a Swarm overlay — not bound to any host port |
| Clickjacking / MIME sniff / referrer leak | Security headers in `caddy/snippet.caddy.template` |
| Force-HTTPS / HSTS | `Strict-Transport-Security: max-age=31536000; includeSubDomains` |
| Server identification | `-Server` header strip in Caddy snippet |
| Lost/compromised root SSH | We don't use root for deploys. Day-to-day deploys use the `deploy` user only. Root requires a Saikat check-in. |
| Weak DB password | `scripts/rotate-secrets.sh` generates 32-char openssl-random secrets |

## What's enforced by CI (cannot be bypassed without editing the workflow)

1. **gitleaks scan** runs on every push and PR. Configured in `.gitleaks.toml`.
2. **pytest + integrity checks** must pass before any image is built.
3. **Trivy scan** runs after the image is pushed (currently report-mode; flip
   `exit-code: "1"` in `.github/workflows/deploy.yml` to fail builds on
   CRITICAL/HIGH vulnerabilities).
4. **Per-server health check** via `curl /health` after deploy. Build fails
   if either app server is unhealthy after rollout.

## Secret management

| Secret | Where it lives | How to rotate |
|---|---|---|
| `HETZNER_BARE_METAL_GITHUB_ACTIONS_SSH_PRIVATE_KEY` | GitHub Secrets | Generate new keypair, push pubkey to `~/.ssh/authorized_keys` on all 3 servers, then update GitHub Secret |
| `POSTGRES_PASSWORD` | GitHub Secrets → Swarm secret | `bash scripts/rotate-secrets.sh --apply` |
| `REPLICATION_PASSWORD` | GitHub Secrets → Swarm secret | `bash scripts/rotate-secrets.sh --apply` |
| `DATABASE_URL_SERVER_1/2` | GitHub Secrets → Docker secret file | Auto-rotated by `rotate-secrets.sh` |
| `BACKUP_S3_ACCESS_KEY` | macOS Keychain → GitHub Secrets | Rotate in Hetzner console, update Keychain: `security add-generic-password -a dolr-ai -s BACKUP_S3_ACCESS_KEY -w NEW_KEY -U`, then re-set on each repo |
| `BACKUP_S3_SECRET_KEY` | macOS Keychain → GitHub Secrets | Same as above |
| `SENTRY_DSN` | GitHub Secrets → env var | Manually via Sentry UI + `gh secret set SENTRY_DSN` |
| `VAULT_TOKEN` (if used) | GitHub Secrets → Docker secret file | Re-issue from Vault, `gh secret set VAULT_TOKEN` |

### S3 backup credential flow

```
macOS Keychain (encrypted at rest)
  ↓ new-service.sh reads via `security find-generic-password`
GitHub Secrets (per-repo, encrypted at rest)
  ↓ backup.yml passes to backup container as env vars
backup.sh configures mc alias → uploads to S3
  ↓ scoped to s3://rishi-yral/${PROJECT_REPO}/ (project isolation)
```

S3 credentials are SHARED across all dolr-ai services (same Hetzner bucket).
Project isolation is enforced at the application level: `backup.sh` and
`restore-from-backup.sh` validate PROJECT_REPO and lock all operations to
the project's own S3 prefix. One project cannot access another's backups.

**Never** check secrets into the repo. The `.gitleaks.toml` allowlist only
permits documented placeholder strings. If gitleaks flags a real secret,
rotate it immediately — assume the value is compromised the moment it lands
in git history.

## Network isolation

```
Internet ─┬─→ Caddy (rishi-1, rishi-2)  port 443
          │       ↓ web (bridge, per-host)
          │   App container (FastAPI)
          │       ↓ db-internal (Swarm overlay, encrypted, per-project)
          │   HAProxy → Patroni leader
          │       ↓ (internal only, no host port binding)
          │   Postgres
          │
          └─→ rishi-3: NO public ports for this service. Patroni only.
```

- The `db-internal` overlay is **per-project**: `${OVERLAY_NETWORK}` from
  project.config. Two services on the same Swarm cannot reach each other's
  Postgres because their overlays don't intersect.
- Postgres has no published host port. The only way in is through HAProxy
  on the per-project overlay.

## Reporting a vulnerability

If you find a security issue in the template, do not open a public GitHub
issue. Email saikat@yral.com (or whoever's on dolr-ai security rotation).

## Hardening you can opt into per project

- **Vault for app secrets**: see [`INTEGRATIONS.md`](INTEGRATIONS.md#2-vault).
  Replaces hardcoded GitHub Secrets with dynamic Vault reads.

## Deferred / cluster-wide TODOs (do these BEFORE anything sensitive ships)

These are important fixes that need more than a single-service change.
Track them so they don't drift.

### 1. Caddy `caddy-ratelimit` plugin
- **What:** the official `caddy:2-alpine` doesn't include the ratelimit module.
  Without it, every endpoint is volumetrically DOS-able (the `/health` endpoint
  alone hits the connection pool).
- **Plan:** build a custom Caddy with `github.com/mholt/caddy-ratelimit` and
  bump the Caddy image on rishi-1 + rishi-2. After that, the commented
  `rate_limit` block in `caddy/snippet.caddy.template` becomes active.
- **Owner:** infra (Saikat — cluster-wide change).

### 2. Postgres `pg_hba.conf` lockdown
- **What:** currently `host all all 0.0.0.0/0 md5`. Postgres is only reachable
  through the `db-internal` Swarm overlay (not the internet), so this isn't
  catastrophic, but it's not defense-in-depth either.
- **Plan:** restrict to the per-project overlay subnet. The hard part is that
  Swarm assigns subnets dynamically; we'd need to either pin subnets in the
  network create call or template `pg_hba` at deploy time.
- **Owner:** template (do this in a future hardening pass).

### 3. Pin third-party GitHub Actions to commit SHAs
- **What:** the workflow uses `appleboy/ssh-action@v1.2.0`, `actions/checkout@v4`,
  `docker/build-push-action@v6`, etc. Tags are mutable; a malicious tag move
  on any of these compromises CI.
- **Plan:** replace each tag with the corresponding commit SHA. Dependabot
  (now enabled in `.github/dependabot.yml`) will keep them updated as PRs.
- **Owner:** template (next hardening pass).

### 4. Container image privilege scan
- **What:** the app runs as a non-root `appuser` (since 2026-04-08), but we
  don't yet drop kernel capabilities (`--cap-drop=ALL`) or use a read-only
  root filesystem.
- **Plan:** add `cap_drop: [ALL]` and `read_only: true` to `docker-compose.yml`,
  with a tmpfs mount for `/tmp`.
- **Owner:** template (next hardening pass).

### 5. Postgres pgBouncer
- **What:** at scale, the per-app connection pool isn't enough. PgBouncer
  between HAProxy and Patroni would handle connection churn.
- **Owner:** infra (when we have a service that needs it).

## Active hardening already in place (as of 2026-04-08)

- App container runs as **non-root `appuser`** (UID 1001) — see `Dockerfile`
- **No public debug endpoints** — `/sentry-test` removed
- **Trivy CRITICAL CVEs fail the build** — Trivy step in CI uses `exit-code: "1"` for CRITICAL
- **Caddy request body limit** — `request_body { max_size 100MB }` in `caddy/snippet.caddy.template` (sized for occasional audio/video uploads while still blocking the trivial 1 GB POST attack)
- **Strict Content-Security-Policy** — `default-src 'none'; frame-ancestors 'none'` baked into the snippet
- **Cross-Origin isolation headers** — COOP/COEP/CORP in the snippet
- **`Cache-Control: no-store`** — default at the edge so secrets-in-responses don't get CDN-cached
- **`gitleaks` on every push**
- **Dependabot weekly scans** — pip + Dockerfile + GitHub Actions
- **`scripts/rotate-secrets.sh`** — turnkey rotation for the 4 DB-related secrets

## Specifically tested against `temp-demo-counter10` (whitehat exercise)

When Saikat does the whitehat pass on a forked service, the things that
should hold up:

| Attack | Expected outcome | Why |
|---|---|---|
| `curl -X POST -H 'Content-Length: 1073741824' …` | 413 from Caddy before reaching the app | `request_body { max_size 100MB }` |
| `curl https://<svc>/sentry-test` | 404 | endpoint removed |
| `curl https://<svc>/`, then `docker exec` to read secrets | container is non-root; `/run/secrets` is RO tmpfs | `Dockerfile USER appuser` + `docker-compose.yml secrets` |
| SQL injection on the counter route | not exploitable | parameterized query, no user input in SQL |
| Reading secrets via `docker inspect` | not exposed | `/run/secrets/database_url` is a file, not an env var |
| TLS 1.0/1.1 handshake | rejected | Caddy default minimum is TLS 1.2 |
| Server fingerprinting via `Server:` | header is stripped | `-Server` in Caddy snippet |
| Reflected XSS via JSON response | CSP blocks any inline script even if injected | `default-src 'none'` |
| Stack traces leaked on 5xx | FastAPI returns generic JSON, no traceback | FastAPI default behavior |
| Anonymous Postgres connect from internet | refused at TCP layer | DB only on `db-internal` overlay, no published port |
