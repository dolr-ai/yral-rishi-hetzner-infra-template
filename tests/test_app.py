"""Smoke tests for the FastAPI app — no real database required."""


def test_root_increments_counter(client):
    r1 = client.get("/")
    r2 = client.get("/")
    assert r1.status_code == 200
    assert r2.status_code == 200
    assert r1.json() == {"message": "Hello World Person 1"}
    assert r2.json() == {"message": "Hello World Person 2"}


def test_health_ok(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "OK", "database": "reachable"}


def test_health_db_down(client, fake_db):
    fake_db.healthy = False
    r = client.get("/health")
    assert r.status_code == 503


def test_root_db_failure_returns_503(client, fake_db, monkeypatch):
    def boom():
        raise RuntimeError("simulated DB failure")
    monkeypatch.setattr("main.get_next_count", boom)
    r = client.get("/")
    assert r.status_code == 503


def test_sentry_test_endpoint_raises(client):
    r = client.get("/sentry-test")
    assert r.status_code == 500
