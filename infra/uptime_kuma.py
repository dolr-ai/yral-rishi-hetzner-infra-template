"""
Uptime Kuma "push monitor" helper.

Usage (call from a /heartbeat endpoint, a cron, or a background task):
    from infra import push_uptime_kuma
    push_uptime_kuma(status="up", msg="OK", ping_ms=12)

Env:
    UPTIME_KUMA_PUSH_URL — full push URL from Uptime Kuma's "push monitor" UI.
                          e.g. https://uptime.yral.com/api/push/abc123
                          If empty, this helper is a no-op (safe for local dev).
"""
import os
from typing import Optional
from urllib.parse import urlencode
from urllib.request import urlopen
from urllib.error import URLError


def push_uptime_kuma(
    status: str = "up",
    msg: str = "OK",
    ping_ms: Optional[int] = None,
    timeout: float = 5.0,
) -> bool:
    """
    Returns True if the push succeeded (or was a no-op), False on failure.
    Never raises — monitoring should not break the caller.
    """
    base = os.environ.get("UPTIME_KUMA_PUSH_URL", "").strip()
    if not base:
        return True  # opt-in; treat unset as success

    params = {"status": status, "msg": msg}
    if ping_ms is not None:
        params["ping"] = str(ping_ms)
    url = f"{base}?{urlencode(params)}"
    try:
        with urlopen(url, timeout=timeout) as r:
            return 200 <= r.status < 300
    except (URLError, TimeoutError, OSError):
        return False
