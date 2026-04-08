# dolr-ai service integrations

Every dolr-ai service deployed from this template should hook into the four
shared platform services. They're all linked from **dashboard.yral.com**.

| Service | URL | Purpose | How to wire it |
|---|---|---|---|
| **Sentry** | apm.yral.com | Error tracking, traces, profiling | `infra.init_sentry()` + `SENTRY_DSN` secret |
| **Vault** | vault.yral.com | Secret storage / rotation | `infra.get_secret()` + `VAULT_TOKEN` secret |
| **Uptime Kuma** | uptime.yral.com | Service uptime + push monitors | `infra.push_uptime_kuma()` + `UPTIME_KUMA_PUSH_URL` env |
| **Beszel** | (dashboard.yral.com) | Server-level CPU/RAM/disk monitoring | Agent already runs on rishi-1/2/3 — nothing to do in-app |

---

## 1. Sentry

```python
# app/main.py
from infra import init_sentry
init_sentry()
app = FastAPI()
```

**GitHub Secrets:**
- `SENTRY_DSN` — create a new project at apm.yral.com, copy the DSN.

**Env vars set by CI** (already wired in `docker-compose.yml`):
- `SENTRY_DSN`, `SENTRY_RELEASE` (= git SHA), `SENTRY_ENVIRONMENT=production`

Verify after deploy: `curl https://your-service.rishi.yral.com/sentry-test`
then check apm.yral.com — the event should appear within ~10s.

## 2. Vault

```python
# Anywhere in your code:
from infra import get_secret
api_key = get_secret("yral-nsfw/openai", "api_key")
```

**GitHub Secrets:**
- `VAULT_TOKEN` — create a service token in Vault scoped to this project's policy.

**Required policy** (create in Vault under `sys/policies/acl/yral-nsfw`):
```hcl
path "secret/data/yral-nsfw/*" { capabilities = ["read"] }
```

The helper reads the token from `/run/secrets/vault_token` first (Docker
secret, preferred) and falls back to `VAULT_TOKEN` env var. Mount the secret
in `docker-compose.yml`:

```yaml
secrets:
  - vault_token
  ...
secrets:
  vault_token:
    file: ./secrets/vault_token
```

CI writes `secrets/vault_token` from `${{ secrets.VAULT_TOKEN }}` the same way
it writes `secrets/database_url`.

## 3. Uptime Kuma

Two integration patterns — pick whichever fits:

**(a) HTTP monitor (no code change):** point Uptime Kuma at
`https://your-service.rishi.yral.com/health`. The /health endpoint already
exists in the template. Set up at uptime.yral.com → "Add new monitor" →
HTTP(s).

**(b) Push monitor (call from inside the app):** use when /health isn't
reachable from the internet (e.g. internal worker).

```python
from infra import push_uptime_kuma
# in a periodic task or healthcheck:
push_uptime_kuma(status="up", msg="OK")
```

Set the env var `UPTIME_KUMA_PUSH_URL` from the "Push" monitor's URL in
Uptime Kuma. Add to `docker-compose.yml`:

```yaml
environment:
  UPTIME_KUMA_PUSH_URL: ${UPTIME_KUMA_PUSH_URL:-}
```

## 4. Beszel

Beszel agents already run on rishi-1, rishi-2, rishi-3 (installed once per
server, not per service). It collects CPU, RAM, disk, network — no in-app
code needed. View at dashboard.yral.com.

If you add a 4th server: SSH in as root once, run the Beszel agent install
command from the Beszel UI ("Add system"), and the new server appears in the
dashboard.

---

## Required GitHub Secrets per integration

| Integration | Secret name | Required? |
|---|---|---|
| Sentry | `SENTRY_DSN` | If you want error tracking |
| Vault | `VAULT_TOKEN` | Only if you call `get_secret()` |
| Uptime Kuma (push) | `UPTIME_KUMA_PUSH_URL` | Only for push-mode |
| Beszel | (none) | Never — runs on the host |

A brand-new stateless service can ship with **just `SENTRY_DSN`** and the
shared `HETZNER_BARE_METAL_GITHUB_ACTIONS_SSH_PRIVATE_KEY`. That's the
minimum. Add the others as needed.
