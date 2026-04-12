# ---------------------------------------------------------------------------
# uptime_kuma.py — sends a "heartbeat" ping to Uptime Kuma monitoring.
#
# WHAT IS UPTIME KUMA?
# Uptime Kuma is a monitoring tool that checks if your services are up.
# It has two modes:
#   1. HTTP monitor: Uptime Kuma hits YOUR /health endpoint every minute
#   2. Push monitor: YOUR code hits Uptime Kuma's URL every minute
#
# This helper implements mode 2 (push monitor). Use it when your /health
# endpoint is not reachable from the internet (e.g., internal workers).
#
# HOW TO USE:
#   from infra import push_uptime_kuma
#   push_uptime_kuma(status="up", msg="OK")
#
# If UPTIME_KUMA_PUSH_URL is not set, this does nothing (safe for local dev).
#
# DEPENDENCIES: none (uses Python's built-in urllib)
# ---------------------------------------------------------------------------

# "os" lets us read the UPTIME_KUMA_PUSH_URL environment variable.
import os

# "Optional" is a type hint that means "this value can be an int OR None."
from typing import Optional

# "urlencode" converts a dictionary to a URL query string.
# Example: {"status": "up", "msg": "OK"} → "status=up&msg=OK"
from urllib.parse import urlencode

# "urlopen" sends an HTTP request and returns the response.
# It's Python's built-in way to make web requests (no extra library needed).
from urllib.request import urlopen

# "URLError" is the error that urlopen raises when the request fails
# (network down, DNS failure, timeout, etc.).
from urllib.error import URLError


def push_uptime_kuma(
    status: str = "up",
    msg: str = "OK",
    ping_ms: Optional[int] = None,
    timeout: float = 5.0,
) -> bool:
    """
    Send a heartbeat ping to Uptime Kuma.

    Parameters:
        status:   "up" or "down" — tells Uptime Kuma if the service is healthy
        msg:      a short message (e.g., "OK" or "DB unreachable")
        ping_ms:  optional response time in milliseconds (for latency tracking)
        timeout:  how long to wait for the ping to complete (seconds)

    Returns:
        True if the ping succeeded (or was a no-op because URL is not set).
        False if the ping failed (network error, timeout).

    IMPORTANT: this function NEVER raises an exception. If the ping fails,
    it returns False silently. Monitoring should not break the service it
    monitors — that would be a cruel irony.
    """
    # Read the push URL from the environment. This is the URL you get from
    # Uptime Kuma's "Push" monitor settings (looks like:
    # https://uptime.yral.com/api/push/abc123)
    base = os.environ.get("UPTIME_KUMA_PUSH_URL", "").strip()

    if not base:
        # No URL configured → monitoring is opt-in. Return True (success)
        # because "not configured" is different from "configured but failing."
        return True

    # Build the query parameters
    params = {"status": status, "msg": msg}
    if ping_ms is not None:
        params["ping"] = str(ping_ms)

    # Combine the base URL with the query string.
    # Example: "https://uptime.yral.com/api/push/abc123?status=up&msg=OK"
    url = f"{base}?{urlencode(params)}"

    try:
        # Send the HTTP request. urlopen returns a response object.
        # "with ... as r:" auto-closes the response when done.
        with urlopen(url, timeout=timeout) as r:
            # Check if the response status code is 2xx (success).
            # 200 = OK, 201 = Created, etc.
            return 200 <= r.status < 300

    except (URLError, TimeoutError, OSError):
        # Network error, timeout, or DNS failure.
        # Return False (ping failed) but don't crash.
        return False
