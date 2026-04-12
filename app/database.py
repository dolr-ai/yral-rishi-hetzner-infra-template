import os
import psycopg2
from psycopg2 import OperationalError, InterfaceError, errors as pg_errors
from psycopg2.pool import ThreadedConnectionPool


def _read_database_url() -> str:
    """
    Read DATABASE_URL from a Docker secret file (preferred) or env var (fallback).

    WHY a secret file?
    Env vars are visible in `docker inspect` to anyone in the docker group on
    the host. Secret files are mounted at /run/secrets/ in tmpfs and never
    appear in any inspect output. CI writes the file before docker compose up.
    """
    secret_file = "/run/secrets/database_url"
    if os.path.exists(secret_file):
        with open(secret_file) as f:
            return f.read().strip()
    return os.environ["DATABASE_URL"]


_KEEPALIVE_OPTS = "keepalives=1&keepalives_idle=30&keepalives_interval=10&keepalives_count=3"

# LAZY pool initialization. The pool is NOT created at import time because:
# 1. On first deploy, the DB may not be reachable yet (HAProxy not converged)
# 2. A crash at import time puts the container into a restart loop that the
#    canary deploy reports as "unhealthy" — the deploy fails even though the
#    DB just needed a few more seconds
# Instead, we create the pool on first request with retry. Once created, it's
# reused for all subsequent requests (fast path = just return _pool).
_pool = None
_database_url = None


def _get_pool():
    """Return the connection pool, creating it lazily on first call."""
    global _pool, _database_url
    if _pool is not None:
        return _pool

    url = _read_database_url()
    url = (
        f"{url}&{_KEEPALIVE_OPTS}" if "?" in url else f"{url}?{_KEEPALIVE_OPTS}"
    )
    _database_url = url

    # Retry pool creation up to 5 times with 2s backoff. This handles the
    # first-deploy race where HAProxy hasn't converged yet.
    import time
    last_err = None
    for attempt in range(5):
        try:
            _pool = ThreadedConnectionPool(minconn=2, maxconn=10, dsn=url)
            return _pool
        except OperationalError as e:
            last_err = e
            time.sleep(2)
    raise last_err


def _execute_with_retry(operation, max_attempts: int = 3):
    """
    Run a database operation with retry on three classes of recoverable error:

    1. Dead connection (OperationalError / InterfaceError):
       psycopg2's ThreadedConnectionPool does NOT validate connections before
       returning them. If a connection in the pool died (network blip, idle
       timeout, leader crash), getconn() happily returns the dead one and the
       next query fails. Discard the connection and try again with a fresh one.

    2. Read-only transaction (psycopg2.errors.ReadOnlySqlTransaction, SQLSTATE
       25006): after a Patroni failover, the app's pooled connection may still
       be talking to the OLD primary which is now a streaming replica. The
       replica accepts SELECT but rejects UPDATE / INSERT / DELETE with this
       error. HAProxy's /master health check will route NEW connections to the
       new leader within ~3s — so dropping the bad connection and retrying
       almost always succeeds on the very next attempt.

    3. Admin shutdown / crash recovery (also OperationalError sometimes, but
       handled by case 1).

    For non-recoverable errors (SQL syntax, constraint violation) we do NOT
    retry — those are bugs and retrying won't help.
    """
    last_exc = None
    for attempt in range(max_attempts):
        pool = _get_pool()
        conn = pool.getconn()
        try:
            result = operation(conn)
            _pool.putconn(conn)
            return result
        except (OperationalError, InterfaceError, pg_errors.ReadOnlySqlTransaction) as e:
            last_exc = e
            # Discard the bad connection from the pool — close=True ensures
            # it's actually closed instead of being returned to bite the next
            # request. For read-only errors this is what forces HAProxy to
            # hand us a connection to the new primary on the next getconn().
            try:
                pool.putconn(conn, close=True)
            except Exception:
                pass
            # Try again with a fresh connection
            continue
        except Exception:
            # Non-connection error — return connection to pool, re-raise
            try:
                pool.putconn(conn)
            except Exception:
                pass
            raise
    # All attempts exhausted
    raise last_exc


def get_next_count() -> int:
    """
    WHY this one SQL statement is race-condition safe:

    WRONG (two statements — race condition if two requests arrive simultaneously):
        SELECT value FROM counter;
        UPDATE counter SET value = 5;  ← someone else might have changed it!

    CORRECT (one atomic operation):
        UPDATE counter SET value = value + 1 WHERE id = 1 RETURNING value;

    PostgreSQL processes this as a single indivisible step. Even 1000 simultaneous
    requests each get a unique sequential number.
    """
    def _do(conn):
        with conn:  # auto-commits on success, rolls back on exception
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE counter SET value = value + 1 WHERE id = 1 RETURNING value;"
                )
                row = cur.fetchone()
                if row is None:
                    raise RuntimeError("Counter row missing — was init.sql run?")
                return row[0]

    return _execute_with_retry(_do)


def check_db_health() -> bool:
    """
    Health check that verifies BOTH database connectivity AND that the
    business table exists. A previous version only did SELECT 1, which
    returned "healthy" even when the counter table was missing (e.g. after
    a failed restore or a dropped table). Now queries the actual table.
    """
    def _do(conn):
        with conn.cursor() as cur:
            cur.execute("SELECT 1 FROM counter LIMIT 1")
            cur.fetchone()
        return True

    try:
        return _execute_with_retry(_do)
    except Exception:
        return False
