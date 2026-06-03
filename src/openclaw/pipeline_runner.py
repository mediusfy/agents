"""Pipeline runner — async background task management for long-running pipelines.

This module provides lightweight in-process background task execution so MCP
tools can submit a pipeline run, return a run_id immediately, and let the
caller poll for completion. No Redis/DB dependency — simple asyncio task + dict.
"""

import asyncio
import logging
import time
import uuid
from datetime import UTC, datetime
from typing import Any

import logfire

logger = logging.getLogger(__name__)

# In-memory store of pipeline runs. Keyed by run_id.
# Each entry: { "status": str, "project": str, "result": str | None,
#               "error": str | None, "started_at": str, "completed_at": str | None,
#               "elapsed_seconds": float | None }
PIPELINE_RUNS: dict[str, dict[str, Any]] = {}


async def submit_pipeline_run(project_name: str, requirement: str) -> str:
    """Submit a pipeline run as a background asyncio task.

    Creates a new asyncio task running main(), records its status in
    PIPELINE_RUNS, and returns the run_id immediately.

    The caller should poll with PIPELINE_RUNS[run_id]["status"] to check
    completion.
    """
    run_id = f"pipe_{uuid.uuid4().hex[:12]}"

    PIPELINE_RUNS[run_id] = {
        "status": "pending",
        "project": project_name,
        "requirement": requirement,
        "result": None,
        "error": None,
        "started_at": datetime.now(UTC).isoformat(),
        "completed_at": None,
        "elapsed_seconds": None,
    }

    # Fire-and-forget background task
    asyncio.create_task(_run_pipeline_in_background(run_id, project_name, requirement))

    return run_id


async def _run_pipeline_in_background(run_id: str, project_name: str, requirement: str) -> None:
    """Run the main pipeline in a background task, updating PIPELINE_RUNS.

    This is the coroutine that runs as a background asyncio task. It captures
    stdout/stderr from the pipeline and updates the run status on completion.
    """
    start_time = time.time()

    with logfire.span("pipeline.background_run", run_id=run_id, project=project_name):
        PIPELINE_RUNS[run_id]["status"] = "running"
        try:
            # Import inside the task to avoid circular imports at module level
            from main import main

            await main(
                project=project_name,
                step="all",
                resume=False,
                auto_yes=True,
                requirement=requirement,
            )
        except asyncio.CancelledError:
            PIPELINE_RUNS[run_id]["status"] = "cancelled"
            PIPELINE_RUNS[run_id]["error"] = "Task was cancelled"
        except Exception as e:
            logger.exception("Pipeline run %s failed: %s", run_id, e)
            PIPELINE_RUNS[run_id]["status"] = "failed"
            PIPELINE_RUNS[run_id]["error"] = f"{type(e).__name__}: {e}"
        else:
            PIPELINE_RUNS[run_id]["status"] = "completed"
            PIPELINE_RUNS[run_id]["result"] = (
                f"Pipeline completed for project '{project_name}'. Artifacts written to generated-app/{project_name}/."
            )
        finally:
            elapsed = time.time() - start_time
            PIPELINE_RUNS[run_id]["completed_at"] = datetime.now(UTC).isoformat()
            PIPELINE_RUNS[run_id]["elapsed_seconds"] = elapsed
