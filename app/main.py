import sentry_sdk
from fastapi import FastAPI, HTTPException

from database import get_next_count, check_db_health
from infra import init_sentry

# Wire Sentry via the shared helper (no-op if SENTRY_DSN is empty).
# See infra/sentry.py + INTEGRATIONS.md for tunables.
init_sentry()

app = FastAPI()


@app.get("/")
def root():
    """
    Every GET request atomically increments the counter and returns the new value.
    Uses PostgreSQL atomic UPDATE...RETURNING — safe even with 1000 simultaneous requests.
    """
    try:
        count = get_next_count()
        return {"message": f"Hello World Person {count}"}
    except Exception as exc:
        # Explicitly capture the underlying exception to Sentry BEFORE
        # re-raising as HTTPException, otherwise Sentry only sees the 503
        # and we lose the database stack trace.
        sentry_sdk.capture_exception(exc)
        raise HTTPException(status_code=503, detail="Database unavailable") from exc


@app.get("/health")
def health():
    """
    Checks both app and database health.
    CI, Uptime Kuma, and Docker healthchecks all hit this.
    """
    if not check_db_health():
        raise HTTPException(
            status_code=503,
            detail={"status": "ERROR", "database": "unreachable"},
        )
    return {"status": "OK", "database": "reachable"}


@app.get("/sentry-test")
def sentry_test():
    """
    Manual probe to verify Sentry is receiving events from production.
    Hit this once after deploy then check apm.yral.com/.../?project=23
    Returns 500 — that's expected.
    """
    # Use the env var so the message is correct for any service forked from this template.
    import os
    raise RuntimeError(f"Sentry test event from {os.environ.get('PROJECT_REPO', 'unknown-service')}")
