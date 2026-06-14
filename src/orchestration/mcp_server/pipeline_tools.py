"""Pipeline orchestration MCP tools — submit, check, cancel, modify, scaffold."""

import asyncio
import logging

import logfire
from pydantic_ai import UsageLimits

from orchestration.agents.registration import register_all_agents
from orchestration.event_broker import Event, EventKind, event_broker
from orchestration.mcp_server import mcp
from orchestration.registry import instrumented_query

logger = logging.getLogger(__name__)


@mcp.tool()
async def run_orchestration_pipeline(project_name: str, requirement: str) -> str:
    """Run the entire multi-agent Orgitration pipeline end-to-end for a given project requirement.

    Because the pipeline can take 10+ minutes, this tool submits the pipeline
    as a background task and returns immediately with a run_id. Poll for
    completion using check_pipeline_status.
    """
    from orchestration.pipeline_jobs import submit_pipeline_run

    run_id = await submit_pipeline_run(project_name, requirement)
    return (
        f"Pipeline run '{run_id}' submitted for project '{project_name}' in the background.\n"
        f"Poll for completion with: check_pipeline_status(run_id='{run_id}')"
    )


@mcp.tool()
async def check_pipeline_status(run_id: str) -> str:
    """Check the status of a background pipeline run.

    Returns current status (pending/running/completed/failed) and any result.
    """
    from orchestration.pipeline_jobs import get_pipeline_run

    run = await get_pipeline_run(run_id)
    if not run:
        return f"No pipeline run found with id '{run_id}'."

    line = f"Run ID: {run_id}\nStatus: {run['status']}\n"
    if run.get("result"):
        line += f"Result: {run['result']}\n"
    if run.get("error"):
        line += f"Error: {run['error']}\n"
    if run.get("completed_at"):
        from datetime import datetime

        dt = datetime.fromisoformat(str(run["completed_at"]).replace("Z", "+00:00"))
        line += f"Completed at: {dt.strftime('%Y-%m-%d %H:%M:%S')}\n"
        elapsed = run.get("elapsed_seconds", 0)
        line += f"Elapsed: {elapsed:.1f}s\n"
    return line


@mcp.tool()
async def cancel_pipeline_run(run_id: str) -> str:
    """Cancel a running background pipeline run by its run_id.

    Sends a cancellation request to the background task. If the task is
    already done (completed, failed, or already cancelled), reports its current status.
    """
    from orchestration.pipeline_jobs import get_pipeline_run

    run = await get_pipeline_run(run_id)
    if not run:
        return f"No pipeline run found with id '{run_id}'."

    status = run["status"]
    if status in ("running", "pending"):
        for task in asyncio.all_tasks():
            if run_id in str(task):
                task.cancel()
                return f"Cancellation sent for run '{run_id}'."
        return f"Run '{run_id}' is {status} but no active task found."
    return f"Run '{run_id}' is already {status}. No cancellation needed."


@mcp.tool()
async def plan_and_execute(goal: str) -> str:
    """Creates a plan to achieve a high-level goal and executes all tasks in dependency order."""
    with logfire.span("mcp.plan_and_execute", goal_length=len(goal), _level="info"):
        from orchestration.agents.planner_agent import planner_agent

        plan_response = await planner_agent.run(
            f"Create a plan to achieve this goal: {goal}",
            usage_limits=UsageLimits(request_limit=500),
        )
        plan = plan_response.output

        completed: set[str] = set()
        results: dict[str, str] = {}

        while len(completed) < len(plan.tasks):
            batch = [t for t in plan.tasks if t.id not in completed and all(dep in completed for dep in t.dependencies)]
            if not batch:
                return f"Plan execution stuck — possible circular dependency.\nPlan: {plan.model_dump_json(indent=2)}"

            async def _run_task(t):
                try:
                    result = await instrumented_query(
                        capability=t.capability,
                        prompt=t.prompt,
                        span_name="mcp.plan_task",
                        attributes={"task_id": t.id, "capability": t.capability},
                    )
                    results[t.id] = result
                except Exception as e:
                    results[t.id] = f"ERROR: {e}"

            await asyncio.gather(*[_run_task(t) for t in batch])

            for t in batch:
                completed.add(t.id)

        summary_lines = [f"## Plan Execution: {goal}", ""]
        for t in plan.tasks:
            status = "✓" if "ERROR" not in results.get(t.id, "") else "✗"
            summary_lines.append(f"  {status} {t.id} ({t.capability}): {t.prompt[:80]}...")
            summary_lines.append(f"     → {results.get(t.id, 'no result')[:200]}")

        return "\n".join(summary_lines)


@mcp.tool()
async def modify_existing_code(change_description: str, codebase_path: str = "") -> str:
    """Modify EXISTING Go backend code through a multi-agent pipeline.

    This runs: service_engineer → test_engineer → quality_gate → review
    Each agent validates the previous one's output.

    Args:
        change_description: What to change and why.
        codebase_path: Path to the existing codebase root. Leave empty to auto-detect.
    """
    with logfire.span(
        "mcp.modify_existing_code",
        change_description_length=len(change_description),
        codebase_path=codebase_path or "auto-detect",
        _level="info",
    ):
        from orchestration.existing_code_handler import format_result_summary, run_existing_code_pipeline

        register_all_agents()

        result = await run_existing_code_pipeline(
            change_description=change_description,
            codebase_path=codebase_path,
            run_tests=True,
            run_quality_gate=True,
            run_review=True,
        )

        return format_result_summary(result)


@mcp.tool()
async def scaffold_and_build_service(service_name: str, bounded_context: str, requirement: str = "") -> str:
    """Scaffold and build a new backend service from scratch using the full Orgitration pipeline.

    Runs the BA → Advisory → Implementation → Test → SRE → Review pipeline.
    """
    with logfire.span(
        "mcp.scaffold_service",
        service_name=service_name,
        bounded_context=bounded_context,
        _level="info",
    ):
        from orchestration.pipeline.config import PipelineConfig
        from orchestration.pipeline.factory import build_pipeline

        requirement = requirement or f"Build a {service_name} service for {bounded_context} bounded context."
        config = PipelineConfig(
            project=service_name,
            step="all",
            blueprint="langgraph_full",
            resume=False,
            auto_yes=True,
            requirement=requirement,
        )
        pipeline = await build_pipeline(config)
        await pipeline.execute()
        return f"Service '{service_name}' scaffolding pipeline completed. Artifacts in generated-app/{service_name}/."


@mcp.tool()
async def submit_async_task(
    task_type: str,
    payload: str,
    callback_tool: str | None = None,
) -> str:
    """Submit a long-running task to the background queue.

    task_type: One of "build", "test_suite", "deploy", "pipeline"
    payload: JSON payload with task parameters
    callback_tool: Optional tool name to call on completion

    Returns:
        task_id — use with check_task_status to poll for results.
    """
    with logfire.span(
        "mcp.submit_async_task",
        task_type=task_type,
        payload_length=len(payload),
        _level="info",
    ):
        task_id = await event_broker.submit(
            Event(
                kind=EventKind.TASK_SUBMITTED,
                data={
                    "type": task_type,
                    "payload": payload,
                    "callback_tool": callback_tool,
                },
            )
        )
        return f"Task '{task_id}' submitted. Use check_task_status('{task_id}') to poll for results."


@mcp.tool()
async def check_task_status(task_id: str) -> str:
    """Check the status of an async task submitted via submit_async_task."""
    with logfire.span("mcp.check_task_status", task_id=task_id, _level="info"):
        status = await event_broker.get_status(task_id)
        if not status:
            return f"Task '{task_id}' not found."
        return f"Task: {task_id}\nStatus: {status.get('status', 'unknown')}\nResult: {status.get('result', 'pending')}"


@mcp.tool()
async def wait_for_task(task_id: str, timeout_seconds: int = 300) -> str:
    """Wait synchronously for an async task to complete (up to timeout_seconds)."""
    with logfire.span("mcp.wait_for_task", task_id=task_id, timeout=timeout_seconds, _level="info"):
        result = await asyncio.wait_for(event_broker.wait_for(task_id, timeout_seconds), timeout_seconds + 10)
        if result is None:
            return f"Task '{task_id}' timed out after {timeout_seconds}s."
        return f"Task: {task_id}\nStatus: {result.get('status', 'completed')}\nResult: {result.get('result', '')}"
