# ---------------------------------------------------------------------------
# main.py — the entry point of the web application.
#
# This is the FIRST file that runs when the app starts. The command
# "uvicorn main:app" tells the web server: "load the file main.py and
# find the variable called 'app' in it."
#
# This file defines TWO web endpoints (URLs the app responds to):
#   GET /        → increments the counter and returns "Hello World Person N"
#   GET /health  → checks if the database is reachable (used by monitoring)
# ---------------------------------------------------------------------------

# "import" means "load this library so I can use its features."
# sentry_sdk is an error-tracking library that sends crash reports to apm.yral.com
import sentry_sdk

# FastAPI is the web framework — it handles all the plumbing of a web server
# (parsing HTTP requests, routing URLs to functions, converting Python dicts to JSON).
# HTTPException is a way to return error responses (like "503 Service Unavailable").
from fastapi import FastAPI, HTTPException

# These are functions from our own database.py file (same folder).
# get_next_count: adds 1 to the counter in PostgreSQL, returns the new number.
# check_db_health: checks if the database is reachable and the counter table exists.
from database import get_next_count, check_db_health

# init_sentry is a helper from our infra/ package that sets up error tracking.
# If the SENTRY_DSN environment variable is not set, this does nothing (safe for local dev).
from infra import init_sentry

# Call init_sentry() at startup. If Sentry is configured, all future errors
# will be automatically reported to apm.yral.com. If not configured, this
# line does nothing — it's a "no-op" (no operation).
init_sentry()

# Create the web application. This is the "app" variable that uvicorn looks for.
# FastAPI handles: receiving HTTP requests, routing them to the right function,
# converting Python dictionaries to JSON responses, and sending them back.
app = FastAPI()


# This is a "decorator" — the @app.get("/") line means:
# "When someone sends a GET request to the URL /, call the function below."
# A GET request is what happens when you type a URL in your browser's address bar.
@app.get("/")
def root():
    """
    The main endpoint. Every visit increments a counter in the database
    and returns the visitor's number.

    Example responses:
      First visitor:  {"message": "Hello World Person 1"}
      Second visitor: {"message": "Hello World Person 2"}
      ...and so on forever.
    """
    # "try" means "attempt the code below, and if anything goes wrong,
    # jump to the 'except' block instead of crashing."
    try:
        # Call our database function to increment the counter.
        # This runs: UPDATE counter SET value = value + 1 RETURNING value;
        # It returns an integer (e.g., 336).
        count = get_next_count()

        # Return a Python dictionary. FastAPI automatically converts this
        # to a JSON response that the browser receives.
        # The f"..." is a "format string" — {count} gets replaced with
        # the actual number (e.g., "Hello World Person 336").
        return {"message": f"Hello World Person {count}"}

    except Exception as exc:
        # If get_next_count() failed (database down, network error, etc.),
        # we land here. "exc" is the error object with details about what broke.

        # Send the error to Sentry FIRST so we have a detailed stack trace
        # in our error dashboard. Without this line, Sentry would only see
        # "HTTPException 503" — not the underlying database error.
        sentry_sdk.capture_exception(exc)

        # Return HTTP 503 (Service Unavailable) to the browser.
        # The user sees: {"detail": "Database unavailable"}
        # "from exc" chains the original error so logs show the root cause.
        raise HTTPException(status_code=503, detail="Database unavailable") from exc


# Another decorator: "when someone sends GET /health, call this function."
# This endpoint is hit every 5 seconds by Docker's healthcheck, by the CI
# deploy verification step, and (optionally) by Uptime Kuma monitoring.
@app.get("/health")
def health():
    """
    Health check endpoint. Returns 200 if the database is reachable and
    the counter table exists. Returns 503 if anything is wrong.

    This is NOT for users — it's for automated monitoring systems.
    """
    # check_db_health() queries: SELECT 1 FROM counter LIMIT 1
    # It returns True if the query succeeds, False if it fails.
    # "not" flips the boolean: "if NOT healthy" → enter the if-block.
    if not check_db_health():
        # Database is unreachable or counter table doesn't exist.
        # Return HTTP 503 with a descriptive JSON body.
        raise HTTPException(
            status_code=503,
            detail={"status": "ERROR", "database": "unreachable"},
        )

    # Database is healthy. Return HTTP 200 with a success message.
    return {"status": "OK", "database": "reachable"}


# NOTE: this template intentionally does NOT ship a public /sentry-test
# endpoint. Earlier versions had one to manually fire a Sentry event after
# deploy, but it was an unauthenticated DOS amplifier (anyone could trigger
# unlimited Sentry events by hitting the URL in a loop). To verify Sentry
# is wired up after a deploy, just trigger a real error path (e.g., stop
# Postgres briefly) and watch the apm.yral.com project.
