"""
pytest fixtures for the template.

The app's `database` module opens a real psycopg2 connection pool at import
time, so we inject a fake `database` module into sys.modules BEFORE importing
app.main. This lets unit tests run with no Postgres available.

For real DB integration tests, see tests/test_local_stack.sh — that one
brings up the full Patroni cluster via local/setup.sh.
"""
import sys
import types
from pathlib import Path

import pytest

# Make `app/` and `infra/` importable from tests/.
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "app"))
sys.path.insert(0, str(ROOT))


class _FakeDB:
    """In-memory counter that mimics the real database module's API."""
    def __init__(self):
        self.value = 0
        self.healthy = True

    def get_next_count(self):
        self.value += 1
        return self.value

    def check_db_health(self):
        return self.healthy


@pytest.fixture
def fake_db(monkeypatch):
    fake = _FakeDB()
    mod = types.ModuleType("database")
    mod.get_next_count = fake.get_next_count
    mod.check_db_health = fake.check_db_health
    monkeypatch.setitem(sys.modules, "database", mod)
    return fake


@pytest.fixture
def client(fake_db, monkeypatch):
    # Ensure no real Sentry DSN leaks into tests
    monkeypatch.delenv("SENTRY_DSN", raising=False)
    # Force-reimport main so it picks up the fake database module
    sys.modules.pop("main", None)
    import main  # noqa: WPS433
    from fastapi.testclient import TestClient
    # raise_server_exceptions=False so /sentry-test returns 500 instead of
    # propagating the RuntimeError out of TestClient.
    return TestClient(main.app, raise_server_exceptions=False)
