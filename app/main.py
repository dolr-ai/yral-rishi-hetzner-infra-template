import logging
import os
import socket

import sentry_sdk
from fastapi import FastAPI, HTTPException
from sentry_sdk.integrations.fastapi import FastApiIntegration
from sentry_sdk.integrations.logging import LoggingIntegration
from sentry_sdk.integrations.starlette import StarletteIntegration

from database import get_next_count, check_db_health

# ----------------------------------------------------------------------------
# Sentry initialization
#
# WHY explicit integrations?
# By default sentry_sdk auto-detects FastAPI/Starlette but enabling them
# explicitly is more reliable across versions and makes the config readable.
#
# WHY traces_sample_rate=1.0?
# This is a low-traffic service. We capture every transaction so the
# performance tab in Sentry actually has data. For high-traffic services
# you'd want 0.1 (10%) or lower to control cost.
#
# WHY server_name?
# Lets you filter Sentry events by which app server they came from
# (rishi-1 vs rishi-2). Helpful when one server has issues.
# ----------------------------------------------------------------------------
sentry_sdk.init(
    dsn=os.environ.get("SENTRY_DSN", ""),
    environment=os.environ.get("SENTRY_ENVIRONMENT", "production"),
    release=os.environ.get("SENTRY_RELEASE"),  # set to git SHA by Dockerfile
    server_name=socket.gethostname(),
    integrations=[
        StarletteIntegration(transaction_style="endpoint"),
        FastApiIntegration(transaction_style="endpoint"),
        LoggingIntegration(level=logging.INFO, event_level=logging.ERROR),
    ],
    traces_sample_rate=1.0,           # capture every transaction (perf monitoring)
    profiles_sample_rate=1.0,         # capture every profile (CPU profiling)
    send_default_pii=False,           # don't send IP addresses, headers, cookies
    attach_stacktrace=True,           # include stack trace on error events
)

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
    raise RuntimeError("Sentry test event from yral-hello-world-counter")
