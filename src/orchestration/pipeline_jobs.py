"""Pipeline jobs — async background task management for long-running pipelines.

This module provides lightweight in-process background task execution so MCP
tools can submit a pipeline run, return a run_id immediately, and let the
caller poll for completion.

Uses a PostgreSQL-backed repository (with in-memory fallback) for persistence.
"""

import asyncio
import logging
import time
import uuid
from typing import Any

import logfire

from orchestration.pipeline.config import PipelineConfig
from orchestration.pipeline.factory import build_pipeline
from orchestration.pipeline_run_repo import run_store

logger = logging.getLogger(__name__)


async def submit_pipeline_run(project_name: str, requirement: str) -> str:
    run_id = f"pipe_{uuid.uuid4().hex[:12]}"

    await run_store.create_run(run_id, project_name, requirement)

    task = asyncio.create_task(_run_pipeline_in_background(run_id, project_name, requirement))
    return run_id


async def _run_pipeline_in_background(run_id: str, project_name: str, requirement: str) -> None:
    start_time = time.time()

    with logfire.span("pipeline.background_run", run_id=run_id, project=project_name):
        await run_store.update_status(run_id, "running")
        try:
            config = PipelineConfig(
                project=project_name,
                step="all",
                blueprint="langgraph_full",
                resume=False,
                auto_yes=True,
                requirement=requirement,
            )
            pipeline = await build_pipeline(config)
            await pipeline.execute()
        except asyncio.CancelledError:
            await run_store.update_status(run_id, "cancelled", error="Task was cancelled")
            raise
        except Exception as e:
            logger.exception("Pipeline run %s failed: %s", run_id, e)
            await run_store.update_status(run_id, "failed", error=f"{type(e).__name__}: {e}")
        else:
            await run_store.update_status(
                run_id,
                "completed",
                result=(
                    f"Pipeline completed for project '{project_name}'. Artifacts written to generated-app/{project_name}/."
                ),
            )
        finally:
            elapsed = time.time() - start_time


async def get_pipeline_run(run_id: str) -> dict[str, Any] | None:
    return await run_store.get_run(run_id)


async def list_pipeline_runs() -> list[dict[str, Any]]:
    return await run_store.list_runs()
