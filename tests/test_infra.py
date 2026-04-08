"""Tests for the infra/ helpers — verify no-op behavior when env vars are unset."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from infra import init_sentry, push_uptime_kuma  # noqa: E402


def test_init_sentry_noop_without_dsn(monkeypatch):
    monkeypatch.delenv("SENTRY_DSN", raising=False)
    # Should not raise
    init_sentry()


def test_push_uptime_kuma_noop_without_url(monkeypatch):
    monkeypatch.delenv("UPTIME_KUMA_PUSH_URL", raising=False)
    assert push_uptime_kuma(status="up", msg="OK") is True


def test_push_uptime_kuma_returns_false_on_bad_url(monkeypatch):
    monkeypatch.setenv("UPTIME_KUMA_PUSH_URL", "http://127.0.0.1:1/nope")
    assert push_uptime_kuma(status="up", msg="OK", timeout=1.0) is False


def test_get_secret_raises_without_token(monkeypatch):
    pytest = __import__("pytest")
    hvac = pytest.importorskip("hvac")  # skip if hvac not installed
    from infra import vault, get_secret
    vault.get_vault_client.cache_clear()
    monkeypatch.delenv("VAULT_TOKEN", raising=False)
    monkeypatch.setattr("os.path.exists", lambda p: False)
    with pytest.raises(RuntimeError, match="VAULT_TOKEN not set"):
        get_secret("foo", "bar")
