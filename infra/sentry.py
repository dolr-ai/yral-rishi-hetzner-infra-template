# ---------------------------------------------------------------------------
# sentry.py — sets up error tracking via Sentry (apm.yral.com).
#
# WHAT IS SENTRY?
# Sentry is an error-tracking service. When your app crashes or throws
# an exception, Sentry captures the error, the stack trace (which line
# of code caused it), and sends it to a dashboard at apm.yral.com.
# You can see all errors across all servers in one place.
#
# HOW TO USE:
#   In app/main.py, just call: init_sentry()
#   If SENTRY_DSN is set → errors are tracked.
#   If SENTRY_DSN is empty → this does nothing (safe for local development).
#
# DEPENDENCIES:
#   - sentry-sdk (installed via requirements.txt)
# ---------------------------------------------------------------------------

# "logging" is Python's built-in logging library.
# We tell Sentry to capture log messages at ERROR level and above.
import logging

# "os" lets us read environment variables (like SENTRY_DSN).
import os

# "socket" lets us get the server's hostname (e.g., "rishi-1") so we can
# see which server an error came from in the Sentry dashboard.
import socket

# The main Sentry SDK — this is what sends errors to apm.yral.com.
import sentry_sdk

# These "integrations" tell Sentry how to hook into specific frameworks:
# - FastApiIntegration: captures errors in FastAPI route handlers
# - LoggingIntegration: captures Python log messages
# - StarletteIntegration: captures errors in Starlette (the library FastAPI is built on)
from sentry_sdk.integrations.fastapi import FastApiIntegration
from sentry_sdk.integrations.logging import LoggingIntegration
from sentry_sdk.integrations.starlette import StarletteIntegration


def init_sentry() -> None:
    """
    Initialize Sentry error tracking. Call this once at app startup.

    If the SENTRY_DSN environment variable is not set (or is empty),
    this function does NOTHING — it's a safe no-op for local development.

    "-> None" means this function doesn't return anything.
    """
    # Read the SENTRY_DSN from the environment. The DSN (Data Source Name)
    # is a URL that tells the Sentry SDK WHERE to send errors.
    # .get("SENTRY_DSN", "") means "get the value, or empty string if not set."
    # .strip() removes any whitespace.
    dsn = os.environ.get("SENTRY_DSN", "").strip()

    if not dsn:
        # No DSN configured → Sentry is opt-in. Do nothing.
        # This is the case during local development.
        return

    # Configure the Sentry SDK with all our settings.
    sentry_sdk.init(
        # WHERE to send errors (the project-specific URL from apm.yral.com)
        dsn=dsn,

        # WHICH environment this is (e.g., "production", "staging", "local")
        # This lets you filter errors by environment in the Sentry dashboard.
        environment=os.environ.get("SENTRY_ENVIRONMENT", "production"),

        # WHICH version of the code is running (the git SHA from CI).
        # This lets you see "this error started happening in commit abc123."
        release=os.environ.get("SENTRY_RELEASE"),

        # WHICH server the error came from (e.g., "rishi-1" or "rishi-2").
        # socket.gethostname() returns the container's hostname.
        server_name=socket.gethostname(),

        # Integrations: tell Sentry how to hook into our frameworks.
        integrations=[
            # Capture errors in Starlette (FastAPI's underlying framework).
            # transaction_style="endpoint" means transactions are named by the
            # route (e.g., "GET /") rather than the URL path.
            StarletteIntegration(transaction_style="endpoint"),

            # Same for FastAPI specifically (builds on top of Starlette).
            FastApiIntegration(transaction_style="endpoint"),

            # Capture Python log messages at INFO level and above.
            # Any log.error() call will create a Sentry event.
            LoggingIntegration(level=logging.INFO, event_level=logging.ERROR),
        ],

        # PERFORMANCE MONITORING: what percentage of requests to trace.
        # 1.0 = 100% (trace every request). For high-traffic services, use
        # 0.1 (10%) to control cost. Low-traffic services can afford 100%.
        traces_sample_rate=float(os.environ.get("SENTRY_TRACES_RATE", "1.0")),

        # PROFILING: what percentage of requests to profile (CPU profiling).
        # Shows which functions are slow. Same cost consideration as traces.
        profiles_sample_rate=float(os.environ.get("SENTRY_PROFILES_RATE", "1.0")),

        # PRIVACY: do NOT send personally identifiable information (PII)
        # like IP addresses, cookies, or request headers to Sentry.
        send_default_pii=False,

        # Include the full stack trace in error events (not just the error message).
        # This makes debugging much easier.
        attach_stacktrace=True,
    )
