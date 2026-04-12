# ---------------------------------------------------------------------------
# infra/ — reusable integration helpers for dolr-ai services.
#
# WHAT IS THIS PACKAGE?
# A "package" in Python is a folder with an __init__.py file. This folder
# contains helper functions that any service forked from the template can
# use. Each helper is OPT-IN: if the relevant environment variable is
# not set, the helper does nothing (safe for local development).
#
# HOW TO USE:
#   from infra import init_sentry      # error tracking
#   from infra import get_secret       # HashiCorp Vault secrets
#   from infra import push_uptime_kuma # uptime monitoring
#
# AVAILABLE HELPERS:
#   init_sentry()       — sets up Sentry error tracking (needs SENTRY_DSN env var)
#   get_vault_client()  — connects to HashiCorp Vault at vault.yral.com (needs VAULT_TOKEN)
#   get_secret()        — reads a secret from Vault (e.g., an API key)
#   push_uptime_kuma()  — pings an Uptime Kuma push monitor (needs UPTIME_KUMA_PUSH_URL)
#
# Beszel (server monitoring) runs as an agent on the server itself — not in the app.
# See INTEGRATIONS.md for details.
# ---------------------------------------------------------------------------

# These "from .module import function" lines make the functions available
# when someone does "from infra import init_sentry". Without them, you'd
# have to write "from infra.sentry import init_sentry" (more typing).
from .sentry import init_sentry
from .vault import get_vault_client, get_secret
from .uptime_kuma import push_uptime_kuma

# __all__ defines what gets exported when someone does "from infra import *".
# It's a list of function names that are the "public API" of this package.
__all__ = [
    "init_sentry",
    "get_vault_client",
    "get_secret",
    "push_uptime_kuma",
]
