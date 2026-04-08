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
| `SENTRY_DSN` | GitHub Secrets → env var | Manually via Sentry UI + `gh secret set SENTRY_DSN` |
| `VAULT_TOKEN` (if used) | GitHub Secrets → Docker secret file | Re-issue from Vault, `gh secret set VAULT_TOKEN` |

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

- **Rate limiting in Caddy**: see the commented `rate_limit` block in
  `caddy/snippet.caddy.template`. Requires a custom Caddy build with the
  ratelimit plugin.
- **Force Trivy to fail builds**: change `exit-code: "0"` to `"1"` in the
  Trivy step of the CI workflow.
- **Vault for app secrets**: see [`INTEGRATIONS.md`](INTEGRATIONS.md#2-vault).
  Replaces hardcoded GitHub Secrets with dynamic Vault reads.
