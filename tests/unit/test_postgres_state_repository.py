"""Tests for PostgresStateRepository checkpoint adapter."""

import json
import pytest
from unittest.mock import AsyncMock, MagicMock, patch

from orchestration.adapters.state_repository import PostgresStateRepository
from orchestration.models.core import PipelineState


@pytest.fixture
def mock_pool():
    """Create a mock asyncpg pool with a mock connection."""
    pool = AsyncMock()
    conn = AsyncMock()
    pool.acquire = MagicMock()
    pool.acquire.return_value.__aenter__ = AsyncMock(return_value=conn)
    pool.acquire.return_value.__aexit__ = AsyncMock(return_value=None)
    return pool, conn


@pytest.fixture
def repo(mock_pool):
    """Create a PostgresStateRepository with a mocked pool."""
    pool, conn = mock_pool
    r = PostgresStateRepository(dsn="postgresql://test:test@localhost:5432/test")
    r._pool = pool
    return r, conn


@pytest.fixture
def sample_state():
    """Create a sample PipelineState for testing."""
    return PipelineState(
        run_id="test-run-123",
        stage="backend",
        requirement="Build a login API",
        attempt=1,
        approved=False,
        feedback=None,
    )


class TestPostgresStateRepositoryInit:
    def test_dsn_env_var(self, monkeypatch):
        monkeypatch.setenv("CHECKPOINT_DSN", "postgresql://env:test@db:5432/checkpoints")
        repo = PostgresStateRepository()
        assert repo._dsn == "postgresql://env:test@db:5432/checkpoints"

    def test_dsn_fallback(self, monkeypatch):
        monkeypatch.delenv("CHECKPOINT_DSN", raising=False)
        monkeypatch.delenv("DATABASE_URL", raising=False)
        from orchestration.settings import settings
        monkeypatch.setattr(settings, "database_url", "postgresql://fallback:test@db:5432/fallback")
        repo = PostgresStateRepository()
        assert repo._dsn == "postgresql://fallback:test@db:5432/fallback"

    def test_dsn_explicit(self):
        repo = PostgresStateRepository(dsn="postgresql://explicit:test@db:5432/explicit")
        assert repo._dsn == "postgresql://explicit:test@db:5432/explicit"


class TestPostgresStateRepositorySave:
    def test_save_creates_checkpoint(self, repo, sample_state):
        r, conn = repo
        r.save("test-run-123", "backend", sample_state)

        conn.execute.assert_awaited_once()
        call_args = conn.execute.call_args[0]
        assert "INSERT INTO pipeline_checkpoints" in call_args[0]
        assert call_args[1] == "test-run-123"
        assert call_args[2] == "backend"
        parsed = json.loads(call_args[3])
        assert parsed["run_id"] == "test-run-123"
        assert parsed["stage"] == "backend"
        assert parsed["requirement"] == "Build a login API"

    def test_save_upserts_on_conflict(self, repo, sample_state):
        r, conn = repo
        sample_state.attempt = 2
        r.save("test-run-123", "backend", sample_state)

        call_args = conn.execute.call_args[0]
        assert "ON CONFLICT" in call_args[0]
        assert "DO UPDATE" in call_args[0]

    def test_save_calls_execute(self):
        conn = AsyncMock()
        pool = MagicMock()
        pool.acquire.return_value.__aenter__ = AsyncMock(return_value=conn)
        pool.acquire.return_value.__aexit__ = AsyncMock(return_value=None)

        r = PostgresStateRepository(dsn="postgresql://test:test@localhost:5432/test")
        r._pool = pool
        r.save("run-1", "stage-1", PipelineState(run_id="run-1", stage="stage-1"))

        assert conn.execute.await_count >= 1


class TestPostgresStateRepositoryLoad:
    def test_load_returns_state(self, repo, sample_state):
        r, conn = repo
        conn.fetchrow = AsyncMock(return_value={"state": json.dumps({
            "run_id": "test-run-123",
            "stage": "backend",
            "requirement": "Build a login API",
            "attempt": 1,
            "approved": False,
            "artifacts": [],
            "errors": [],
        })})

        result = r.load("test-run-123", "backend")

        assert result is not None
        assert result.run_id == "test-run-123"
        assert result.stage == "backend"
        assert result.requirement == "Build a login API"
        assert result.attempt == 1

    def test_load_returns_none_when_missing(self, repo):
        r, conn = repo
        conn.fetchrow = AsyncMock(return_value=None)

        result = r.load("nonexistent-run", "backend")
        assert result is None

    def test_load_handles_corrupted_state(self, repo):
        r, conn = repo
        conn.fetchrow = AsyncMock(return_value={"state": "{invalid json"})

        result = r.load("test-run-123", "backend")
        assert result is None


class TestPostgresStateRepositoryExists:
    def test_exists_returns_true(self, repo):
        r, conn = repo
        conn.fetchval = AsyncMock(return_value=1)

        assert r.exists("test-run-123", "backend") is True

    def test_exists_returns_false(self, repo):
        r, conn = repo
        conn.fetchval = AsyncMock(return_value=None)

        assert r.exists("test-run-123", "backend") is False


class TestPostgresStateRepositoryClear:
    def test_clear_deletes_checkpoints(self, repo):
        r, conn = repo
        conn.execute = AsyncMock(return_value="DELETE 2")

        r.clear("test-run-123")

        conn.execute.assert_awaited_once()
        assert "DELETE FROM pipeline_checkpoints" in conn.execute.call_args[0][0]


class TestPostgresStateRepositoryFindLatest:
    def test_find_latest_returns_run_id(self, repo):
        r, conn = repo
        conn.fetchval = AsyncMock(return_value="test-run-123")

        result = r.find_latest_run_id()
        assert result == "test-run-123"

    def test_find_latest_returns_none_when_empty(self, repo):
        r, conn = repo
        conn.fetchval = AsyncMock(return_value=None)

        result = r.find_latest_run_id()
        assert result is None
