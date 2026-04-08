"""
Sentry initialization for dolr-ai FastAPI services.

Usage in app/main.py:
    from infra import init_sentry
    init_sentry()
    app = FastAPI()

Reads from env:
    SENTRY_DSN          — project DSN from apm.yral.com (no-op if missing)
    SENTRY_ENVIRONMENT  — defaults to "production"
    SENTRY_RELEASE      — git SHA, set by CI/Dockerfile
    SENTRY_TRACES_RATE  — float 0..1, defaults to 1.0 (low-traffic services)
"""
import logging
import os
import socket

import sentry_sdk
from sentry_sdk.integrations.fastapi import FastApiIntegration
from sentry_sdk.integrations.logging import LoggingIntegration
from sentry_sdk.integrations.starlette import StarletteIntegration


def init_sentry() -> None:
    dsn = os.environ.get("SENTRY_DSN", "").strip()
    if not dsn:
        # Sentry is opt-in. Empty DSN = local dev or stripped template.
        return

    sentry_sdk.init(
        dsn=dsn,
        environment=os.environ.get("SENTRY_ENVIRONMENT", "production"),
        release=os.environ.get("SENTRY_RELEASE"),
        server_name=socket.gethostname(),
        integrations=[
            StarletteIntegration(transaction_style="endpoint"),
            FastApiIntegration(transaction_style="endpoint"),
            LoggingIntegration(level=logging.INFO, event_level=logging.ERROR),
        ],
        traces_sample_rate=float(os.environ.get("SENTRY_TRACES_RATE", "1.0")),
        profiles_sample_rate=float(os.environ.get("SENTRY_PROFILES_RATE", "1.0")),
        send_default_pii=False,
        attach_stacktrace=True,
    )
