"""PipelineRunRepository — PostgreSQL-backed persistence for pipeline run state.

Phase 3.2: replaces the in-memory ``PIPELINE_RUNS`` dict with a database-backed
repository. Falls back to an in-memory dict when PostgreSQL is unavailable.
"""

import asyncio
import logging
from datetime import UTC, datetime
from typing import Any

from orchestration.vector_db import _dsn

logger = logging.getLogger(__name__)

_RUN_TABLE = "pipeline_runs"


class InMemoryRunStore:
    """Fallback in-memory store when PostgreSQL is unavailable."""

    def __init__(self):
        self._runs: dict[str, dict[str, Any]] = {}

    async def create_run(self, run_id: str, project: str, requirement: str) -> dict[str, Any]:
        record = {
            "run_id": run_id,
            "status": "pending",
            "project": project,
            "requirement": requirement,
            "result": None,
            "error": None,
            "started_at": datetime.now(UTC).isoformat(),
            "completed_at": None,
            "elapsed_seconds": None,
        }
        self._runs[run_id] = record
        return record

    async def update_status(
        self,
        run_id: str,
        status: str,
        result: str | None = None,
        error: str | None = None,
    ) -> None:
        record = self._runs.get(run_id)
        if record is None:
            return
        record["status"] = status
        if result is not None:
            record["result"] = result
        if error is not None:
            record["error"] = error
        if status in ("completed", "failed", "cancelled"):
            record["completed_at"] = datetime.now(UTC).isoformat()

    async def get_run(self, run_id: str) -> dict[str, Any] | None:
        return self._runs.get(run_id)

    async def list_runs(self) -> list[dict[str, Any]]:
        return list(self._runs.values())


class PostgresRunStore:
    """PostgreSQL-backed run storage using asyncpg."""

    def __init__(self):
        self._pool = None
        self._lock = asyncio.Lock()

    async def _ensure_pool(self):
        if self._pool is not None:
            return
        async with self._lock:
            if self._pool is not None:
                return
            import asyncpg

            dsn = _dsn()
            self._pool = await asyncpg.create_pool(dsn, min_size=1, max_size=3)
            async with self._pool.acquire() as conn:
                await conn.execute(f"""
                    CREATE TABLE IF NOT EXISTS {_RUN_TABLE} (
                        run_id         TEXT PRIMARY KEY,
                        project        TEXT NOT NULL,
                        requirement    TEXT NOT NULL DEFAULT '',
                        status         TEXT NOT NULL DEFAULT 'pending',
                        result         TEXT,
                        error          TEXT,
                        started_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                        completed_at   TIMESTAMPTZ,
                        elapsed_seconds DOUBLE PRECISION
                    )
                """)

    async def create_run(self, run_id: str, project: str, requirement: str) -> dict[str, Any]:
        await self._ensure_pool()
        async with self._pool.acquire() as conn:
            await conn.execute(
                f"""
                INSERT INTO {_RUN_TABLE} (run_id, project, requirement, status, started_at)
                VALUES ($1, $2, $3, 'pending', NOW())
                """,
                run_id,
                project,
                requirement,
            )
        return await self.get_run(run_id) or {}

    async def update_status(
        self,
        run_id: str,
        status: str,
        result: str | None = None,
        error: str | None = None,
    ) -> None:
        await self._ensure_pool()
        async with self._pool.acquire() as conn:
            if status in ("completed", "failed", "cancelled"):
                await conn.execute(
                    f"""
                    UPDATE {_RUN_TABLE}
                    SET status = $1, result = COALESCE($2, result),
                        error = COALESCE($3, error),
                        completed_at = NOW(),
                        elapsed_seconds = EXTRACT(EPOCH FROM NOW() - started_at)
                    WHERE run_id = $4
                    """,
                    status,
                    result,
                    error,
                    run_id,
                )
            else:
                await conn.execute(
                    f"""
                    UPDATE {_RUN_TABLE}
                    SET status = $1, result = COALESCE($2, result), error = COALESCE($3, error)
                    WHERE run_id = $4
                    """,
                    status,
                    result,
                    error,
                    run_id,
                )

    async def get_run(self, run_id: str) -> dict[str, Any] | None:
        await self._ensure_pool()
        async with self._pool.acquire() as conn:
            row = await conn.fetchrow(
                f"SELECT * FROM {_RUN_TABLE} WHERE run_id = $1", run_id
            )
            if row is None:
                return None
            return dict(row)

    async def list_runs(self) -> list[dict[str, Any]]:
        await self._ensure_pool()
        async with self._pool.acquire() as conn:
            rows = await conn.fetch(f"SELECT * FROM {_RUN_TABLE} ORDER BY started_at DESC")
            return [dict(r) for r in rows]


def _create_store() -> PostgresRunStore | InMemoryRunStore:
    try:
        import asyncpg  # noqa: F401

        return PostgresRunStore()
    except ImportError:
        logger.warning("asyncpg unavailable — pipeline runs stored in memory")
        return InMemoryRunStore()


run_store: PostgresRunStore | InMemoryRunStore = _create_store()
