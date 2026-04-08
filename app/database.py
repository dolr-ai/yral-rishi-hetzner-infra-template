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


# Add TCP keepalives to detect dead connections within ~60 seconds.
# WHY keepalives?
# Without them, a connection can sit "open" for hours after the network path
# died (Patroni failover, HAProxy backend swap, NAT timeout). The OS default
# is ~2 hours before the kernel notices. With these settings:
#   - Idle connections start sending keepalive probes after 30 seconds
#   - Probes every 10 seconds
#   - 3 missed probes = connection dead
#   - Total: ~60 seconds to detect a dead connection
DATABASE_URL = _read_database_url()
_KEEPALIVE_OPTS = "keepalives=1&keepalives_idle=30&keepalives_interval=10&keepalives_count=3"
DATABASE_URL = (
    f"{DATABASE_URL}&{_KEEPALIVE_OPTS}"
    if "?" in DATABASE_URL
    else f"{DATABASE_URL}?{_KEEPALIVE_OPTS}"
)

# Connection pool shared across all FastAPI requests.
# minconn=2:  keep 2 connections warm so the first request after idle is fast
# maxconn=10: scale up to 10 under concurrent load (per app container)
_pool = ThreadedConnectionPool(minconn=2, maxconn=10, dsn=DATABASE_URL)


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
        conn = _pool.getconn()
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
                _pool.putconn(conn, close=True)
            except Exception:
                pass
            # Try again with a fresh connection
            continue
        except Exception:
            # Non-connection error — return connection to pool, re-raise
            try:
                _pool.putconn(conn)
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
    """Quick liveness check — runs SELECT 1 with retry on dead connections."""
    def _do(conn):
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
            cur.fetchone()
        return True

    try:
        return _execute_with_retry(_do)
    except Exception:
        return False
