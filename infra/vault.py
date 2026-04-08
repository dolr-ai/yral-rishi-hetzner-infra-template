"""
HashiCorp Vault helper for dolr-ai services.

Usage:
    from infra import get_secret
    db_password = get_secret("kv/data/yral-nsfw/db", "password")

Why a wrapper:
    - Single place to set the address (vault.yral.com) and auth method
    - Lazy client init so importing this module doesn't fail when Vault is down
    - Falls back to env var if VAULT_ADDR/VAULT_TOKEN are missing (local dev)

Env vars:
    VAULT_ADDR      — defaults to https://vault.yral.com
    VAULT_TOKEN     — service token (inject via Docker secret in production)
    VAULT_NAMESPACE — optional, for Vault Enterprise namespaces
"""
import os
from functools import lru_cache
from typing import Any, Optional

DEFAULT_VAULT_ADDR = "https://vault.yral.com"


@lru_cache(maxsize=1)
def get_vault_client():
    """Returns a cached hvac.Client. Raises ImportError if hvac not installed."""
    try:
        import hvac  # type: ignore
    except ImportError as e:
        raise ImportError(
            "hvac is required for Vault integration. Add `hvac` to requirements.txt."
        ) from e

    token = _read_token()
    if not token:
        raise RuntimeError(
            "VAULT_TOKEN not set (env var or /run/secrets/vault_token). "
            "Cannot authenticate to Vault."
        )

    client = hvac.Client(
        url=os.environ.get("VAULT_ADDR", DEFAULT_VAULT_ADDR),
        token=token,
        namespace=os.environ.get("VAULT_NAMESPACE") or None,
    )
    if not client.is_authenticated():
        raise RuntimeError("Vault token rejected — check VAULT_TOKEN value")
    return client


def _read_token() -> Optional[str]:
    """Prefer Docker secret file, fall back to env var."""
    secret_path = "/run/secrets/vault_token"
    if os.path.exists(secret_path):
        with open(secret_path) as f:
            return f.read().strip()
    return os.environ.get("VAULT_TOKEN")


def get_secret(path: str, key: str, mount_point: str = "secret") -> Any:
    """
    Read a single key from a KV-v2 secret.

    path: e.g. "yral-nsfw/db"  (without the leading "data/")
    key:  field within the secret
    mount_point: KV engine mount, defaults to "secret"
    """
    client = get_vault_client()
    resp = client.secrets.kv.v2.read_secret_version(path=path, mount_point=mount_point)
    return resp["data"]["data"][key]
