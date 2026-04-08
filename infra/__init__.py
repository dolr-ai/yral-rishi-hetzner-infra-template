"""
infra/ — reusable dolr-ai service integrations.

Import these from app/main.py instead of copy-pasting integration boilerplate
across services. Every helper is opt-in: if the relevant env var is missing,
the helper is a no-op.

Available helpers:
    init_sentry()       — wires sentry_sdk with FastAPI/Starlette/Logging integrations
    get_vault_client()  — returns an hvac.Client authed against vault.yral.com
    push_uptime_kuma()  — pings an Uptime Kuma push monitor (call from /health or a cron)

Beszel runs as an agent on the server (not in-app) — see infra/README.md.
"""
from .sentry import init_sentry
from .vault import get_vault_client, get_secret
from .uptime_kuma import push_uptime_kuma

__all__ = [
    "init_sentry",
    "get_vault_client",
    "get_secret",
    "push_uptime_kuma",
]
