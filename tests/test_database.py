"""
Unit tests for the database retry logic in app/database.py.

These tests verify that _execute_with_retry correctly handles:
  - Success on the first attempt (happy path)
  - Recoverable errors that succeed on retry (dead connection, failover)
  - All retries exhausted (raises the last error)
  - Non-recoverable errors (re-raised immediately, no retry)
  - Connection cleanup (bad connections are closed, good ones are returned)

WHY THESE TESTS MATTER:
The retry logic is what keeps the app running during Patroni failovers.
If it silently breaks (e.g., someone refactors and forgets the
ReadOnlySqlTransaction case), the app would crash on every failover
instead of transparently reconnecting.
"""
import os
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

# Ensure app/ is importable
ROOT = Path(__file__).resolve().parent.parent
if str(ROOT / "app") not in sys.path:
    sys.path.insert(0, str(ROOT / "app"))

from psycopg2 import OperationalError, InterfaceError, errors as pg_errors


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _import_fresh_database():
    """
    Import database.py with a fresh module state.

    database.py uses module-level globals (_pool, _database_url).
    To get a clean slate for each test, we remove it from sys.modules
    and re-import.
    """
    sys.modules.pop("database", None)
    import database
    return database


# ---------------------------------------------------------------------------
# Tests for _execute_with_retry
# ---------------------------------------------------------------------------

class TestExecuteWithRetry:
    """Tests for the core retry logic."""

    def test_success_on_first_attempt(self):
        """Happy path: operation succeeds, connection returned to pool."""
        db = _import_fresh_database()
        pool = MagicMock()
        conn = MagicMock()
        pool.getconn.return_value = conn
        db._pool = pool

        def operation(c):
            return 42

        result = db._execute_with_retry(operation)

        assert result == 42
        # Connection should be returned to the pool (not closed)
        pool.putconn.assert_called_once_with(conn)

    def test_retry_on_operational_error(self):
        """OperationalError on first try, success on second."""
        db = _import_fresh_database()
        pool = MagicMock()
        bad_conn = MagicMock(name="bad_conn")
        good_conn = MagicMock(name="good_conn")
        pool.getconn.side_effect = [bad_conn, good_conn]
        db._pool = pool

        call_count = 0

        def operation(c):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                raise OperationalError("connection reset by peer")
            return 99

        result = db._execute_with_retry(operation)

        assert result == 99
        assert call_count == 2
        # First connection should be closed (close=True), second returned normally
        assert pool.putconn.call_count == 2
        pool.putconn.assert_any_call(bad_conn, close=True)
        pool.putconn.assert_any_call(good_conn)

    def test_retry_on_interface_error(self):
        """InterfaceError (broken connection object) triggers retry."""
        db = _import_fresh_database()
        pool = MagicMock()
        bad_conn = MagicMock(name="bad_conn")
        good_conn = MagicMock(name="good_conn")
        pool.getconn.side_effect = [bad_conn, good_conn]
        db._pool = pool

        call_count = 0

        def operation(c):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                raise InterfaceError("connection already closed")
            return 77

        result = db._execute_with_retry(operation)

        assert result == 77
        assert call_count == 2

    def test_retry_on_read_only_transaction(self):
        """
        ReadOnlySqlTransaction triggers retry.

        This is the FAILOVER case: the app still has a connection to the
        old leader, which is now a read-only replica. The retry gets a
        fresh connection that goes through HAProxy to the new leader.
        """
        db = _import_fresh_database()
        pool = MagicMock()
        old_leader_conn = MagicMock(name="old_leader")
        new_leader_conn = MagicMock(name="new_leader")
        pool.getconn.side_effect = [old_leader_conn, new_leader_conn]
        db._pool = pool

        call_count = 0

        def operation(c):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                raise pg_errors.ReadOnlySqlTransaction(
                    "cannot execute UPDATE in a read-only transaction"
                )
            return 55

        result = db._execute_with_retry(operation)

        assert result == 55
        assert call_count == 2
        # The old connection (to the demoted leader) should be closed
        pool.putconn.assert_any_call(old_leader_conn, close=True)

    def test_all_retries_exhausted(self):
        """All attempts fail with OperationalError — raises the last one."""
        db = _import_fresh_database()
        pool = MagicMock()
        db._pool = pool

        def always_fail(c):
            raise OperationalError("database is down")

        with pytest.raises(OperationalError, match="database is down"):
            db._execute_with_retry(always_fail, max_attempts=3)

        # Should have gotten 3 connections (one per attempt)
        assert pool.getconn.call_count == 3

    def test_non_recoverable_error_not_retried(self):
        """
        Non-recoverable errors (ValueError, TypeError, SQL syntax errors)
        are re-raised immediately without retry.
        """
        db = _import_fresh_database()
        pool = MagicMock()
        conn = MagicMock()
        pool.getconn.return_value = conn
        db._pool = pool

        def bad_sql(c):
            raise ValueError("invalid input")

        with pytest.raises(ValueError, match="invalid input"):
            db._execute_with_retry(bad_sql)

        # Should have been called only ONCE (no retry for non-recoverable)
        assert pool.getconn.call_count == 1
        # Connection should be returned to pool (not closed — it's probably fine)
        pool.putconn.assert_called_once_with(conn)

    def test_custom_max_attempts(self):
        """max_attempts parameter controls retry count."""
        db = _import_fresh_database()
        pool = MagicMock()
        db._pool = pool

        def always_fail(c):
            raise OperationalError("down")

        with pytest.raises(OperationalError):
            db._execute_with_retry(always_fail, max_attempts=5)

        assert pool.getconn.call_count == 5


# ---------------------------------------------------------------------------
# Tests for _get_pool (lazy initialization)
# ---------------------------------------------------------------------------

class TestGetPool:
    """Tests for the lazy pool initialization."""

    def test_returns_existing_pool(self):
        """If pool already exists, return it immediately (no reconnection)."""
        db = _import_fresh_database()
        existing_pool = MagicMock()
        db._pool = existing_pool

        result = db._get_pool()
        assert result is existing_pool

    def test_creates_pool_on_first_call(self):
        """First call creates a new pool with correct parameters."""
        db = _import_fresh_database()
        db._pool = None

        mock_pool_instance = MagicMock()

        with patch.object(db, "_read_database_url", return_value="postgresql://localhost/test"), \
             patch("database.ThreadedConnectionPool", return_value=mock_pool_instance) as mock_cls:
            result = db._get_pool()

        assert result is mock_pool_instance
        mock_cls.assert_called_once()
        # Verify minconn and maxconn
        _, kwargs = mock_cls.call_args
        assert kwargs["minconn"] == 2
        assert kwargs["maxconn"] == 10
        # Verify keepalive params are appended to the DSN
        assert "keepalives=1" in kwargs["dsn"]

    def test_retries_on_connection_failure(self):
        """Pool creation retries up to 5 times if the DB isn't ready."""
        db = _import_fresh_database()
        db._pool = None

        mock_pool_instance = MagicMock()

        with patch.object(db, "_read_database_url", return_value="postgresql://localhost/test"), \
             patch("database.ThreadedConnectionPool") as mock_cls, \
             patch("time.sleep"):
            # Fail twice, succeed on third attempt
            mock_cls.side_effect = [
                OperationalError("connection refused"),
                OperationalError("connection refused"),
                mock_pool_instance,
            ]
            result = db._get_pool()

        assert result is mock_pool_instance
        assert mock_cls.call_count == 3


# ---------------------------------------------------------------------------
# Tests for check_db_health
# ---------------------------------------------------------------------------

class TestCheckDbHealth:
    """Tests for the health check function."""

    def test_returns_false_on_any_error(self):
        """check_db_health catches ALL exceptions and returns False."""
        db = _import_fresh_database()
        pool = MagicMock()
        db._pool = pool

        # Make EVERY connection's operation raise — so all 3 retries fail,
        # then check_db_health's except catches the final OperationalError
        def failing_getconn():
            conn = MagicMock()
            # The operation inside check_db_health does:
            #   with conn.cursor() as cur: cur.execute(...)
            # We make execute() raise on every connection.
            # The cursor is used as a context manager, so __enter__ must
            # return the cursor itself (not a fresh MagicMock).
            cursor = MagicMock()
            cursor.execute.side_effect = OperationalError("relation 'counter' does not exist")
            cursor.__enter__ = MagicMock(return_value=cursor)
            cursor.__exit__ = MagicMock(return_value=False)
            conn.cursor.return_value = cursor
            return conn

        pool.getconn.side_effect = lambda: failing_getconn()

        result = db.check_db_health()
        assert result is False

    def test_returns_true_when_healthy(self):
        """check_db_health returns True when the query succeeds."""
        db = _import_fresh_database()
        pool = MagicMock()
        conn = MagicMock()
        pool.getconn.return_value = conn
        db._pool = pool

        # Default MagicMock behavior: cursor().execute() succeeds,
        # cursor().fetchone() returns a MagicMock (truthy)
        result = db.check_db_health()
        assert result is True
