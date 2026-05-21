import asyncio
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

import logging

import logfire
from mcp.server.fastmcp import FastMCP

from openclaw.agents.accountant import AccountantDeps, accountant_agent
from openclaw.agents.asymmetric_reviewer import AsymmetricReviewerDeps, asymmetric_reviewer_agent
from openclaw.agents.current_events import CurrentEventsDeps, current_events_agent
from openclaw.agents.non_technical.holiday_planner import HolidayPlannerDeps, holiday_planner_agent
from openclaw.agents.region_analyzer import RegionAnalyzerDeps, region_analyzer_agent
from openclaw.agents.weather import WeatherDeps, weather_agent
from openclaw.vector_db import vector_db

logfire.configure()
logfire.instrument_pydantic()
logging.basicConfig(level=logging.INFO)

mcp = FastMCP("OpenClaw")
if hasattr(mcp, "app"):
    logfire.instrument_fastapi(mcp.app)


def create_agent_runner(agent, deps_class, tool_name: str, docstring: str):
    """Factory to create an MCP tool for running an agent."""

    async def agent_runner(request: str) -> str:
        deps = deps_class(pass_num=1)
        result = await agent.run(request, deps=deps)
        return result.data

    agent_runner.__doc__ = docstring
    agent_runner.__name__ = tool_name
    return mcp.tool(name=tool_name)(agent_runner)


# ── Travel & Finance Agent Tools

run_holiday_planner = create_agent_runner(
    holiday_planner_agent, HolidayPlannerDeps, "run_holiday_planner", "Invokes the Holiday Planner Agent."
)
run_region_analyzer = create_agent_runner(
    region_analyzer_agent, RegionAnalyzerDeps, "run_region_analyzer", "Invokes the Region Analyzer Agent."
)
run_asymmetric_reviewer = create_agent_runner(
    asymmetric_reviewer_agent,
    AsymmetricReviewerDeps,
    "run_asymmetric_reviewer",
    "Invokes the Asymmetric Reviewer Agent (law & corporate tricks for travel savings).",
)
run_current_events = create_agent_runner(
    current_events_agent, CurrentEventsDeps, "run_current_events", "Invokes the Current Events Agent (history buff)."
)
run_weather = create_agent_runner(weather_agent, WeatherDeps, "run_weather", "Invokes the Weather Agent.")
run_accountant = create_agent_runner(
    accountant_agent, AccountantDeps, "run_accountant", "Invokes the Accountant Agent."
)

# ── SDLC / Existing Code Tools


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
    'frontend_dev', 'infra_advice', 'db_schema',
    'service_engineer' (existing code mods, use modify_existing_code tool instead),
    'go_test' (Go table-driven tests), 'quality_gate' (over-engineering check), etc.
    For modifying existing code, prefer the 'modify_existing_code' tool.
    """
    from openclaw.agents.registration import register_all_agents
    from openclaw.registry import registry

    register_all_agents()

    full_prompt = f"Context from IDE:\n{context}\n\nTask:\n{task}"
    return await registry.query(capability, full_prompt)


@mcp.tool()
async def run_openclaw_pipeline(project_name: str, requirement: str) -> str:
    """Run the entire multi-agent OpenClaw pipeline end-to-end for a given project requirement."""
    from main import main

    os.environ["REQUIREMENT"] = requirement
    await main(project=project_name, step="all", resume=False, auto_yes=True)
    return f"Pipeline completed for {project_name}. Artifacts written to disk."


@mcp.tool()
async def plan_and_execute(goal: str) -> str:
    """Creates a plan to achieve a high-level goal and executes all tasks in dependency order."""
    from openclaw.agents.planner_agent import planner_agent
    from openclaw.registry import registry

    plan_response = await planner_agent.run(f"Create a plan to achieve this goal: {goal}")
    plan = plan_response.data

    completed: set[str] = set()
    results: dict[str, str] = {}

    while len(completed) < len(plan.tasks):
        batch = [t for t in plan.tasks if t.id not in completed and all(dep in completed for dep in t.dependencies)]
        if not batch:
            return f"Plan execution stuck — possible circular dependency.\nPlan: {plan.model_dump_json(indent=2)}"

        async def _run_task(t):
            try:
                result = await registry.query(t.capability, t.prompt)
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
    from openclaw.agents.registration import register_all_agents
    from openclaw.existing_code_handler import format_result_summary, run_existing_code_pipeline

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
    """
    Scaffold and build a new backend service from scratch using the full OpenClaw pipeline.
    This runs the BA → Advisory → Implementation → Test → SRE → Review pipeline.
    """
    from main import main

    requirement = requirement or f"Build a {service_name} service for {bounded_context} bounded context."
    os.environ["REQUIREMENT"] = requirement
    await main(project=service_name, step="all", resume=False, auto_yes=True)
    return f"Service '{service_name}' scaffolding pipeline completed. Artifacts in generated-app/{service_name}/."


if __name__ == "__main__":
    mcp.run()
