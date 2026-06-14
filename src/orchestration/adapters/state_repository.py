import abc
import json
import logging
import os
import uuid

from orchestration.models.core import PipelineState
from orchestration.settings import settings

logger = logging.getLogger(__name__)


class StateRepositoryPort(abc.ABC):
    """
    Port for saving and loading PipelineState. This decouples the CheckpointManager
    from local disk I/O, allowing for DB-backed state persistence in the future.
    """

    @abc.abstractmethod
    def save(self, run_id: str, stage: str, state: PipelineState) -> None:
        pass

    @abc.abstractmethod
    def load(self, run_id: str, stage: str) -> PipelineState | None:
        pass

    @abc.abstractmethod
    def exists(self, run_id: str, stage: str) -> bool:
        pass

    @abc.abstractmethod
    def clear(self, run_id: str) -> None:
        pass

    @abc.abstractmethod
    def find_latest_run_id(self) -> str | None:
        pass


class LocalDiskStateRepository(StateRepositoryPort):
    """
    Local filesystem implementation of the StateRepositoryPort.
    """

    def __init__(self, project_name: str):
        self.project_name = project_name
        self.checkpoint_dir = os.path.join(str(settings.checkpoint_dir), project_name)
        os.makedirs(self.checkpoint_dir, exist_ok=True)

    def _get_filepath(self, run_id: str, stage: str) -> str:
        safe_stage = stage.replace("/", "_").replace(" ", "_")
        return os.path.join(self.checkpoint_dir, f"{run_id}_{safe_stage}.json")

    def save(self, run_id: str, stage: str, state: PipelineState) -> None:
        filepath = self._get_filepath(run_id, stage)
        try:
            data = state.model_dump_json()
        except AttributeError:
            data = state.json()

        # Atomic write
        tmp_path = f"{filepath}.tmp"
        with open(tmp_path, "w") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, filepath)
        logger.info(f"State saved to disk: stage='{stage}' at {os.path.relpath(filepath)}")

    def load(self, run_id: str, stage: str) -> PipelineState | None:
        filepath = self._get_filepath(run_id, stage)
        if not os.path.exists(filepath):
            return None
        try:
            with open(filepath) as f:
                data = json.load(f)
            try:
                return PipelineState.model_validate(data)
            except AttributeError:
                return PipelineState.parse_obj(data)
        except (json.JSONDecodeError, KeyError, TypeError) as e:
            logger.warning(f"Corrupted checkpoint for stage '{stage}': {e}")
            return None

    def exists(self, run_id: str, stage: str) -> bool:
        return os.path.exists(self._get_filepath(run_id, stage))

    def clear(self, run_id: str) -> None:
        if not os.path.isdir(self.checkpoint_dir):
            return
        count = 0
        for filename in os.listdir(self.checkpoint_dir):
            if filename.startswith(run_id):
                os.remove(os.path.join(self.checkpoint_dir, filename))
                count += 1
        logger.info(f"State cleared: {count} files for run {run_id}")

    def find_latest_run_id(self) -> str | None:
        if not os.path.isdir(self.checkpoint_dir):
            return None
        try:
            files = [f for f in os.listdir(self.checkpoint_dir) if f.endswith(".json")]
            if not files:
                return None
            files.sort(key=lambda x: os.path.getmtime(os.path.join(self.checkpoint_dir, x)), reverse=True)
            latest = files[0]
            run_id = latest.split("_")[0]
            try:
                uuid.UUID(run_id)
                return run_id
            except ValueError:
                return None
        except Exception as e:
            logger.warning(f"Error finding latest run: {e}")
            return None


class PostgresStateRepository(StateRepositoryPort):
    """
    PostgreSQL-backed implementation of the StateRepositoryPort using asyncpg.

    Stores PipelineState checkpoints in a `pipeline_checkpoints` table.
    Uses CHECKPOINT_DSN env var (falls back to DATABASE_URL).
    """

    def __init__(self, dsn: str | None = None):
        self._dsn = dsn or os.environ.get("CHECKPOINT_DSN") or settings.database_url or "postgresql://localhost:5432/orchestration"
        self._pool = None

    async def _ensure_pool(self):
        if self._pool is None:
            import asyncpg
            self._pool = await asyncpg.create_pool(self._dsn, min_size=1, max_size=3)
            async with self._pool.acquire() as conn:
                await conn.execute("""
                    CREATE TABLE IF NOT EXISTS pipeline_checkpoints (
                        run_id      TEXT NOT NULL,
                        stage       TEXT NOT NULL,
                        state       JSONB NOT NULL,
                        created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                        updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                        PRIMARY KEY (run_id, stage)
                    )
                """)
        return self._pool

    def save(self, run_id: str, stage: str, state: PipelineState) -> None:
        import asyncio
        try:
            asyncio.get_running_loop()
        except RuntimeError:
            asyncio.run(self._async_save(run_id, stage, state))
        else:
            import threading
            t = threading.Thread(target=lambda: asyncio.run(self._async_save(run_id, stage, state)), daemon=True)
            t.start()
            t.join()

    async def _async_save(self, run_id: str, stage: str, state: PipelineState):
        pool = await self._ensure_pool()
        data = state.model_dump_json()
        async with pool.acquire() as conn:
            await conn.execute(
                """
                INSERT INTO pipeline_checkpoints (run_id, stage, state, updated_at)
                VALUES ($1, $2, $3::jsonb, NOW())
                ON CONFLICT (run_id, stage)
                DO UPDATE SET state = EXCLUDED.state, updated_at = NOW()
                """,
                run_id,
                stage,
                data,
            )
        logger.info("State saved to Postgres: run=%s stage=%s", run_id, stage)

    def load(self, run_id: str, stage: str) -> PipelineState | None:
        import asyncio
        return asyncio.run(self._async_load(run_id, stage))

    async def _async_load(self, run_id: str, stage: str) -> PipelineState | None:
        pool = await self._ensure_pool()
        async with pool.acquire() as conn:
            row = await conn.fetchrow(
                "SELECT state FROM pipeline_checkpoints WHERE run_id = $1 AND stage = $2",
                run_id,
                stage,
            )
        if not row:
            return None
        try:
            return PipelineState.model_validate_json(row["state"])
        except Exception as e:
            logger.warning("Corrupted checkpoint for run=%s stage=%s: %s", run_id, stage, e)
            return None

    def exists(self, run_id: str, stage: str) -> bool:
        import asyncio
        return asyncio.run(self._async_exists(run_id, stage))

    async def _async_exists(self, run_id: str, stage: str) -> bool:
        pool = await self._ensure_pool()
        async with pool.acquire() as conn:
            row = await conn.fetchval(
                "SELECT 1 FROM pipeline_checkpoints WHERE run_id = $1 AND stage = $2",
                run_id,
                stage,
            )
            return row == 1

    def clear(self, run_id: str) -> None:
        import asyncio
        asyncio.run(self._async_clear(run_id))

    async def _async_clear(self, run_id: str):
        pool = await self._ensure_pool()
        async with pool.acquire() as conn:
            result = await conn.execute(
                "DELETE FROM pipeline_checkpoints WHERE run_id = $1",
                run_id,
            )
        logger.info("Cleared %s checkpoints for run=%s", result, run_id)

    def find_latest_run_id(self) -> str | None:
        import asyncio
        return asyncio.run(self._async_find_latest_run_id())

    async def _async_find_latest_run_id(self) -> str | None:
        pool = await self._ensure_pool()
        async with pool.acquire() as conn:
            row = await conn.fetchval(
                "SELECT run_id FROM pipeline_checkpoints ORDER BY updated_at DESC LIMIT 1"
            )
            return row
