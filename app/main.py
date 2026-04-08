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


# NOTE: this template intentionally does NOT ship a public /sentry-test
# endpoint. Earlier versions had one to manually fire a Sentry event after
# deploy, but it was an unauthenticated DOS amplifier. To verify Sentry is
# wired up after a deploy, just trigger a real error path (e.g. stop Postgres
# briefly) and watch the apm.yral.com project — no permanent attack surface.
