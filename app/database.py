# ---------------------------------------------------------------------------
# database.py — how the app talks to PostgreSQL.
#
# This file manages the connection between the Python app and the PostgreSQL
# database. It handles three hard problems:
#
#   1. CONNECTION POOLING — keeping a set of pre-opened connections so each
#      request doesn't need to open a new one (opening is slow, ~50ms).
#
#   2. FAILOVER RECOVERY — detecting when a connection is broken (database
#      leader changed, network blip) and automatically retrying with a
#      fresh connection.
#
#   3. SECURITY — reading the database password from a file (not an
#      environment variable) so it's never visible in `docker inspect`.
#
# DEPENDENCIES:
#   - psycopg2 (installed via requirements.txt) — the Python adapter for PostgreSQL
#   - PostgreSQL must be reachable via HAProxy on the Docker overlay network
# ---------------------------------------------------------------------------

# "os" is Python's built-in module for interacting with the operating system.
# We use it to check if files exist and read environment variables.
import os

# "psycopg2" is the Python library for talking to PostgreSQL databases.
# It lets us connect, run SQL queries, and get results back.
import psycopg2

# These are specific ERROR TYPES from psycopg2:
# - OperationalError: database connection died, server crashed, etc.
# - InterfaceError: the connection object itself is broken (not just the query)
# - pg_errors: a collection of PostgreSQL-specific error classes, including
#   ReadOnlySqlTransaction (the error you get when trying to write to a replica)
from psycopg2 import OperationalError, InterfaceError, errors as pg_errors

# ThreadedConnectionPool is a POOL of database connections that's safe to use
# from multiple threads simultaneously. Think of it as a "parking lot" of
# pre-opened connections: when a request needs the database, it "checks out"
# a connection, uses it, then "returns" it to the pool for the next request.
from psycopg2.pool import ThreadedConnectionPool


def _read_database_url() -> str:
    """
    Read the DATABASE_URL (the connection string that tells us WHERE the
    database is and HOW to authenticate).

    Example: postgresql://postgres:mypassword@haproxy-rishi-1:5432/my_db

    The URL is read from a FILE (not an environment variable) for security:
    - Files mounted at /run/secrets/ are in tmpfs (RAM-only, never on disk)
    - They're NOT visible in `docker inspect` output
    - CI writes this file before starting the container

    If the file doesn't exist (e.g., in local development), we fall back
    to the DATABASE_URL environment variable.

    The "-> str" means this function returns a string.
    """
    # Path where Docker mounts the secret file inside the container
    secret_file = "/run/secrets/database_url"

    # os.path.exists() returns True if the file is there, False if not
    if os.path.exists(secret_file):
        # "with open(...) as f" opens the file and auto-closes it when done.
        # f.read() reads the entire contents as a string.
        # .strip() removes any leading/trailing whitespace or newlines.
        with open(secret_file) as f:
            return f.read().strip()

    # Fallback: read from the DATABASE_URL environment variable.
    # os.environ["DATABASE_URL"] raises an error if it's not set — that's
    # intentional. If we can't find the database URL anywhere, crashing
    # with a clear error is better than silently malfunctioning.
    return os.environ["DATABASE_URL"]


# TCP keepalive settings, appended to the database URL as query parameters.
# These tell the operating system to periodically check if the network
# connection to the database is still alive. Without them:
#   - A connection can sit "open" for HOURS after the network path died
#   - The default OS timeout is ~2 hours before it notices
# With these settings:
#   - keepalives=1          → enable TCP keepalives
#   - keepalives_idle=30    → start probing after 30 seconds of silence
#   - keepalives_interval=10 → probe every 10 seconds
#   - keepalives_count=3    → declare dead after 3 missed probes
#   - Total: ~60 seconds to detect a dead connection
_KEEPALIVE_OPTS = "keepalives=1&keepalives_idle=30&keepalives_interval=10&keepalives_count=3"

# ---------------------------------------------------------------------------
# LAZY POOL INITIALIZATION
#
# The pool is NOT created when this file loads (at "import time"). Instead,
# it's created the first time a web request needs the database.
#
# WHY? When the Docker container starts, Python imports all files. If we
# tried to connect to the database here and it wasn't ready yet (HAProxy
# still booting, Patroni still electing a leader), the ENTIRE APP would
# crash before it even started — and the canary deploy would report
# "unhealthy" even though the DB just needed a few more seconds.
#
# With lazy init: the app starts fine (uvicorn is running, /health can
# respond), and the FIRST real request triggers pool creation. By that
# time the database is usually ready. If it's still not ready, we retry
# 5 times with 2-second pauses.
# ---------------------------------------------------------------------------

# _pool starts as None (no pool exists yet).
# "global" variables that start with _ are "private by convention" — other
# files shouldn't access them directly.
_pool = None
_database_url = None


def _get_pool():
    """
    Return the connection pool. If it doesn't exist yet, create it.

    "global" means "I want to modify these module-level variables, not
    create new local ones inside this function."

    Returns: a ThreadedConnectionPool object.
    """
    global _pool, _database_url

    # Fast path: if the pool already exists, return it immediately.
    # This is the case for 99.99% of requests (only the very first one creates it).
    if _pool is not None:
        return _pool

    # Slow path: first request. Read the database URL and create the pool.
    url = _read_database_url()

    # Append the keepalive settings to the URL.
    # If the URL already has query parameters (contains "?"), use "&" to add more.
    # If not, start the query string with "?".
    url = (
        f"{url}&{_KEEPALIVE_OPTS}" if "?" in url else f"{url}?{_KEEPALIVE_OPTS}"
    )
    _database_url = url

    # "import time" — we import the time module HERE (not at the top of the file)
    # because it's only needed during pool creation, which happens once.
    import time

    # Try up to 5 times to create the pool. Each attempt waits 2 seconds
    # before retrying. This handles the "first deploy" race condition where
    # HAProxy hasn't converged to the database leader yet.
    last_err = None
    for attempt in range(5):
        try:
            # Create the pool:
            #   minconn=2  → keep 2 connections open even when idle (faster first request)
            #   maxconn=10 → allow up to 10 simultaneous connections (for concurrent requests)
            #   dsn=url    → the database URL to connect to
            _pool = ThreadedConnectionPool(minconn=2, maxconn=10, dsn=url)
            return _pool
        except OperationalError as e:
            # Connection failed (database not ready yet). Save the error and retry.
            last_err = e
            time.sleep(2)  # Wait 2 seconds before trying again

    # If we get here, all 5 attempts failed. Raise the last error.
    raise last_err


def _execute_with_retry(operation, max_attempts: int = 3):
    """
    Run a database operation with automatic retry on recoverable errors.

    WHAT IS "operation"?
    A function that takes a database connection and does something with it.
    For example: a function that runs "UPDATE counter SET value = value + 1".

    WHY RETRY?
    Three things can go wrong that are TEMPORARY (not bugs):

    1. DEAD CONNECTION: the connection in the pool was open, but the
       network path died (server crash, timeout). The pool doesn't check
       connections before handing them out, so we discover they're dead
       only when we try to use them. Fix: discard it, get a fresh one.

    2. READ-ONLY ERROR: after a database leader changes (failover), the
       app might still have connections to the OLD leader, which is now
       a read-only replica. Writing to a replica fails with a specific
       error. Fix: discard the connection (new one goes to new leader).

    3. ADMIN SHUTDOWN: Patroni restarting PostgreSQL. Same fix: retry.

    For NON-recoverable errors (SQL typos, constraint violations), we do
    NOT retry — those are bugs in our code and retrying won't help.

    Parameters:
        operation:    a function that takes a connection and returns a result
        max_attempts: how many times to try (default: 3)

    Returns: whatever the operation returns (e.g., the counter value).
    """
    last_exc = None  # Store the last error in case we need to raise it

    # Try up to max_attempts times
    for attempt in range(max_attempts):
        # Get the connection pool (creates it lazily if first request)
        pool = _get_pool()

        # "Check out" a connection from the pool (like borrowing a book from a library)
        conn = pool.getconn()

        try:
            # Run the operation (e.g., UPDATE counter...)
            result = operation(conn)

            # Success! "Return" the connection to the pool for the next request.
            pool.putconn(conn)

            # Return the result to the caller
            return result

        except (OperationalError, InterfaceError, pg_errors.ReadOnlySqlTransaction) as e:
            # RECOVERABLE error: dead connection, read-only, or admin shutdown.
            last_exc = e  # Save the error

            # DISCARD the bad connection (close=True means "don't put it back
            # in the pool — actually close the TCP connection").
            try:
                pool.putconn(conn, close=True)
            except Exception:
                pass  # If even discarding fails, just move on

            # Loop back to the top: get a FRESH connection and try again
            continue

        except Exception:
            # NON-RECOVERABLE error (e.g., SQL syntax error, constraint violation).
            # Return the connection to the pool (it's probably fine) and re-raise
            # the error to the caller — retrying won't fix a bug.
            try:
                pool.putconn(conn)
            except Exception:
                pass
            raise  # "raise" without arguments re-raises the current exception

    # All attempts exhausted. Raise the last error to the caller.
    raise last_exc


def get_next_count() -> int:
    """
    Increment the counter in the database and return the new value.

    HOW IT WORKS:
    Runs ONE SQL statement that does TWO things atomically (as a single
    indivisible step):
      1. Adds 1 to the counter
      2. Returns the new value

    "Atomically" means PostgreSQL treats this as a single operation.
    Even if 1000 users hit the URL at the exact same moment, each one
    gets a unique sequential number. No duplicates, no gaps (under normal
    operation — gaps can happen if a transaction rolls back).

    WHY NOT TWO STATEMENTS?
      Step 1: SELECT value FROM counter;        → reads 42
      Step 2: UPDATE counter SET value = 43;     → writes 43
      BUT: between step 1 and step 2, another request might also read 42
      and also write 43 — we lost a count! This is a "race condition."

    The RETURNING keyword lets us do it in one step:
      UPDATE counter SET value = value + 1 WHERE id = 1 RETURNING value;

    Returns: the new counter value as an integer (e.g., 337).
    """
    # Define a small function that takes a connection and runs the SQL.
    # This function gets passed to _execute_with_retry(), which handles
    # the connection management and error recovery.
    def _do(conn):
        # "with conn:" opens a transaction. If the code inside succeeds,
        # the transaction is committed (saved). If it fails, the transaction
        # is rolled back (undone). This prevents partial writes.
        with conn:
            # "with conn.cursor() as cur:" creates a "cursor" — an object
            # that lets us run SQL queries and read results.
            with conn.cursor() as cur:
                # Run the SQL query
                cur.execute(
                    "UPDATE counter SET value = value + 1 WHERE id = 1 RETURNING value;"
                )

                # Read the result. fetchone() returns ONE row as a tuple,
                # e.g., (337,). row[0] gets the first element: 337.
                row = cur.fetchone()

                # If the counter row doesn't exist (someone deleted it),
                # raise an error with a helpful message.
                if row is None:
                    raise RuntimeError("Counter row missing — was init.sql run?")

                # Return the counter value (an integer)
                return row[0]

    # Pass _do to _execute_with_retry, which:
    # 1. Gets a connection from the pool
    # 2. Calls _do(conn)
    # 3. If it fails with a connection error, retries with a fresh connection
    # 4. Returns the result (the counter value)
    return _execute_with_retry(_do)


def check_db_health() -> bool:
    """
    Health check: verifies the database is reachable AND the counter table exists.

    A previous version only did "SELECT 1" which returned "healthy" even when
    the counter table was missing (e.g., after a failed restore or a dropped
    table). The app would report "healthy" to the monitoring system while
    returning 503 errors to actual users. Now we query the actual table.

    Returns: True if healthy, False if anything is wrong.
    """
    def _do(conn):
        with conn.cursor() as cur:
            # Query the counter table to verify it exists AND is readable.
            # LIMIT 1 means "just check one row" — fast regardless of table size.
            cur.execute("SELECT 1 FROM counter LIMIT 1")
            cur.fetchone()
        return True

    try:
        return _execute_with_retry(_do)
    except Exception:
        # ANY error (connection failed, table missing, permission denied, etc.)
        # → report as unhealthy. The caller (main.py's /health endpoint)
        # will return HTTP 503.
        return False
