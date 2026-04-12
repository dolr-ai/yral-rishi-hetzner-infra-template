# ---------------------------------------------------------------------------
# vault.py — helper for reading secrets from HashiCorp Vault.
#
# WHAT IS HASHICORP VAULT?
# Vault is a secrets management service (like a secure password manager
# for your applications). Instead of hardcoding API keys and passwords
# in your code or environment variables, you store them in Vault and
# your app reads them at runtime. Vault lives at vault.yral.com.
#
# WHY USE VAULT?
# - Secrets are stored encrypted, with audit logging (who accessed what)
# - Secrets can be rotated without redeploying your app
# - Each service gets its own access policy (can only read its own secrets)
# - Much better than GitHub Secrets for sensitive, frequently-rotated keys
#
# HOW TO USE:
#   from infra import get_secret
#   api_key = get_secret("yral-myservice/openai", "api_key")
#
# WHEN TO USE:
# Use Vault for secrets that change frequently or are very sensitive
# (API keys, third-party tokens). For database passwords that rarely
# change, Docker Swarm secrets (the current approach) are simpler.
#
# DEPENDENCIES:
# - hvac (NOT in requirements.txt by default — add it when you need Vault)
#   Install: pip install hvac
# ---------------------------------------------------------------------------

# "os" lets us read environment variables and check if files exist.
import os

# "lru_cache" is a CACHING decorator. When applied to a function, it
# remembers the result of the first call and returns it on subsequent
# calls WITHOUT running the function again. This means we only connect
# to Vault ONCE, not on every request.
# "LRU" stands for "Least Recently Used" — a caching strategy.
from functools import lru_cache

# "Any" and "Optional" are TYPE HINTS — they tell humans (and code editors)
# what types a function accepts/returns. They don't affect runtime behavior.
# Any = can be any type (string, number, dict, etc.)
# Optional[str] = can be a string OR None
from typing import Any, Optional

# The default Vault server address. Can be overridden by setting the
# VAULT_ADDR environment variable (e.g., for a self-hosted Vault).
DEFAULT_VAULT_ADDR = "https://vault.yral.com"


# @lru_cache(maxsize=1) means:
# "Cache the result of this function. Only keep 1 cached result.
#  After the first call, return the cached Vault client instead of
#  creating a new one."
@lru_cache(maxsize=1)
def get_vault_client():
    """
    Get an authenticated Vault client. Creates and caches it on first call.

    Returns: an hvac.Client object (the Vault Python library's client).

    Raises:
        ImportError: if hvac is not installed (add it to requirements.txt)
        RuntimeError: if VAULT_TOKEN is not set or the token is rejected
    """
    # Try to import the hvac library. It's NOT installed by default
    # (not in requirements.txt) because most services don't need Vault.
    # When a service DOES need it, the developer adds "hvac" to
    # requirements.txt.
    try:
        import hvac  # type: ignore  ← tells type checkers to ignore this line
    except ImportError as e:
        # hvac not installed → give a helpful error message
        raise ImportError(
            "hvac is required for Vault integration. Add `hvac` to requirements.txt."
        ) from e

    # Read the authentication token (needed to prove who we are to Vault)
    token = _read_token()
    if not token:
        raise RuntimeError(
            "VAULT_TOKEN not set (env var or /run/secrets/vault_token). "
            "Cannot authenticate to Vault."
        )

    # Create the Vault client:
    # - url: the Vault server address
    # - token: our authentication token
    # - namespace: optional, for Vault Enterprise multi-tenancy
    client = hvac.Client(
        url=os.environ.get("VAULT_ADDR", DEFAULT_VAULT_ADDR),
        token=token,
        namespace=os.environ.get("VAULT_NAMESPACE") or None,
    )

    # Verify the token actually works (Vault didn't reject it)
    if not client.is_authenticated():
        raise RuntimeError("Vault token rejected — check VAULT_TOKEN value")

    return client


def _read_token() -> Optional[str]:
    """
    Read the Vault authentication token.

    Checks two places (in order):
    1. /run/secrets/vault_token — Docker Swarm secret file (preferred in production)
    2. VAULT_TOKEN environment variable — fallback (for local development)

    Returns the token as a string, or None if not found in either place.
    """
    # First try: Docker Swarm secret file (more secure)
    secret_path = "/run/secrets/vault_token"
    if os.path.exists(secret_path):
        with open(secret_path) as f:
            return f.read().strip()

    # Fallback: environment variable (less secure but works locally)
    return os.environ.get("VAULT_TOKEN")


def get_secret(path: str, key: str, mount_point: str = "secret") -> Any:
    """
    Read a single secret value from Vault.

    HOW VAULT ORGANIZES SECRETS:
    Vault stores secrets in a tree structure, like folders on your computer:
      secret/
        yral-myservice/
          db → {"username": "postgres", "password": "abc123"}
          openai → {"api_key": "sk-xxx"}

    Parameters:
        path:        the path to the secret (e.g., "yral-myservice/db")
        key:         which field to read (e.g., "password")
        mount_point: the Vault "engine" name (usually "secret")

    Returns: the value of the requested key (e.g., "abc123").

    Example:
        password = get_secret("yral-myservice/db", "password")
        # password is now "abc123"
    """
    # Get the cached Vault client (created on first call, reused after)
    client = get_vault_client()

    # Read the secret from Vault's KV-v2 (Key-Value version 2) engine.
    # The response is a nested dictionary:
    #   {"data": {"data": {"username": "postgres", "password": "abc123"}, ...}}
    # We drill into ["data"]["data"][key] to get the actual value.
    resp = client.secrets.kv.v2.read_secret_version(path=path, mount_point=mount_point)
    return resp["data"]["data"][key]
