import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

import logging

import logfire
from mcp.server.fastmcp import FastMCP

from openclaw.vector_db import vector_db

logfire.configure()
logfire.instrument_pydantic()
logging.basicConfig(level=logging.INFO)

mcp = FastMCP("OpenClaw")
if hasattr(mcp, "app"):
    logfire.instrument_fastapi(mcp.app)


@mcp.tool()
def search_adrs(query: str) -> str:
    """Search existing Architecture Decision Records (ADRs) to ensure new advice doesn't contradict past rulings."""
    results = vector_db.search("adrs", query)
    if not results:
        return f"No ADRs found for query: {query}"
    return "Found past architectural context:\n" + "\n---\n".join(results)


@mcp.tool()
def save_adr(decision_id: str, content: str) -> str:
    """Save a new Architecture Decision Record (ADR) to the knowledge base."""
    vector_db.add_documents("adrs", [content], [{"id": decision_id}], [decision_id])
    return f"Saved ADR {decision_id} successfully."


@mcp.tool()
async def delegate_to_openclaw_agent(capability: str, context: str, task: str) -> str:
    """
    Delegate a heavy-lifting engineering task to the OpenClaw autonomous agents.
    Available capabilities: 'requirements_analysis', 'arch_review', 'backend_dev',
    'frontend_dev', 'infra_advice', 'db_schema', 'service_engineer' (existing code modification),
    'go_test' (Go table-driven tests), 'quality_gate' (over-engineering check), etc.
    """
    from openclaw.a2a import agent_bus
    from openclaw.registry import registry

    registry.autodiscover()

    full_prompt = f"Context from IDE:\n{context}\n\nTask:\n{task}"
    result = await agent_bus.query(capability, full_prompt)
    return result


@mcp.tool()
async def run_openclaw_pipeline(project_name: str, requirement: str) -> str:
    """Run the entire multi-agent OpenClaw pipeline end-to-end for a given project requirement."""
    import os

    from main import main

    os.environ["REQUIREMENT"] = requirement
    await main(project=project_name, step="all", resume=False, auto_yes=True)
    return f"Pipeline completed for {project_name}. Artifacts written to disk."


@mcp.tool()
async def plan_and_execute(goal: str) -> str:
    """Creates a plan to achieve a high-level goal and dispatches the tasks"""
    from openclaw.a2a import agent_bus
    from openclaw.agents.planner_agent import planner_agent

    plan_response = await planner_agent.run(f"Create a plan to achieve this goal: {goal}")
    plan = plan_response.data

    for task in plan.tasks:
        if not task.dependencies:
            agent_bus.dispatch_task(task.capability, task.prompt)

    return f"Plan created and initial tasks dispatched. Plan: {plan.model_dump_json(indent=2)}"


@mcp.tool()
async def modify_existing_code(change_description: str, codebase_path: str = "") -> str:
    """
    Modify EXISTING Go backend code through a multi-agent pipeline.
    Use this when you have an existing Go service that needs changes — adding handlers,
    wiring dependencies, refactoring, fixing bugs, adding tracing, or extending features.

    This runs: service_engineer → test_engineer → quality_gate → review
    Each agent validates the previous one's output.

    Args:
        change_description: What to change and why (e.g., "Add OpenTelemetry tracing
            to the ProcessMessage handler in internal/service/message.go")
        codebase_path: Path to the existing codebase root. Leave empty to auto-detect.
    """
    from openclaw.agents.registration import register_pipeline_agents

    register_pipeline_agents()

    from openclaw.existing_code_handler import (
        format_result_summary,
        run_existing_code_pipeline,
    )

    result = await run_existing_code_pipeline(
        change_description=change_description,
        codebase_path=codebase_path,
        run_tests=True,
        run_quality_gate=True,
        run_review=True,
    )

    return format_result_summary(result)


if __name__ == "__main__":
    mcp.run()
