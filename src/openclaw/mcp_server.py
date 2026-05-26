import asyncio
import logging
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

import logfire
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

from openclaw.agents.non_technical.accountant import AccountantDeps, accountant_agent
from openclaw.agents.non_technical.asymmetric_reviewer import AsymmetricReviewerDeps, asymmetric_reviewer_agent
from openclaw.agents.non_technical.current_events import CurrentEventsDeps, current_events_agent
from openclaw.agents.non_technical.holiday_planner import HolidayPlannerDeps, holiday_planner_agent
from openclaw.agents.non_technical.region_analyzer import RegionAnalyzerDeps, region_analyzer_agent
from openclaw.agents.non_technical.weather import WeatherDeps, weather_agent
from openclaw.observability import configure_observability
from openclaw.vector_db import vector_db

logger = logging.getLogger(__name__)

configure_observability()

logging.basicConfig(level=logging.INFO)

mcp = FastMCP(
    "OpenClaw",
    transport_security=TransportSecuritySettings(
        enable_dns_rebinding_protection=os.environ.get("MCP_DNS_REBINDING_PROTECTION", "1") == "1"
    ),
)

# ── Instrumented agent runner factory ───────────────────────────────────


def create_agent_runner(agent, deps_class, tool_name: str, docstring: str):
    """Factory to create an MCP tool for running an agent, with Logfire span."""

    async def agent_runner(request: str) -> str:
        with logfire.span(
            "mcp.run_agent",
            tool_name=tool_name,
            request_length=len(request),
            _level="info",
        ):
            deps = deps_class()
            result = await agent.run(request, deps=deps)
            return result.output

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
    with logfire.span("mcp.search_adrs", query_length=len(query), _level="info"):
        results = vector_db.search("adrs", query)
        if not results:
            return f"No ADRs found for query: {query}"
        return "Found past architectural context:\n" + "\n---\n".join(results)


@mcp.tool()
def save_adr(decision_id: str, content: str) -> str:
    """Save a new Architecture Decision Record (ADR) to the knowledge base."""
    with logfire.span("mcp.save_adr", decision_id=decision_id, _level="info"):
        vector_db.add_documents("adrs", [content], [{"id": decision_id}], [decision_id])
        return f"Saved ADR {decision_id} successfully."


def _list_capabilities() -> str:
    """Return the live list of capabilities → agent owners, sorted alphabetically.

    Used to keep the delegate_to_openclaw_agent docstring honest at runtime.
    """
    from openclaw.agents.registration import register_all_agents
    from openclaw.registry import registry

    register_all_agents()
    lines = []
    for cap, owners in registry.capabilities():
        primary = owners[0]
        rest = f"  (also: {', '.join(owners[1:])})" if len(owners) > 1 else ""
        lines.append(f"  - {cap}: {primary}{rest}")
    return "\n".join(lines)


@mcp.tool()
async def delegate_to_openclaw_agent(capability: str, context: str, task: str) -> str:
    """
    Delegate a heavy-lifting engineering task to the OpenClaw autonomous agents.

    Pass a capability string registered via openclaw.agents.registration; common
    ones include 'backend', 'frontend', 'database', 'security', 'review',
    'quality_gate', 'go_test', 'planning', 'sre', 'docs'. The full live list is
    available via the list_openclaw_capabilities tool — call that first if you
    are not sure which capability fits the task.

    For modifying existing code, prefer the 'modify_existing_code' tool.
    """
    from openclaw.agents.registration import register_all_agents
    from openclaw.exceptions import AgentExecutionError, AgentNotFoundError
    from openclaw.registry import instrumented_query

    register_all_agents()

    full_prompt = f"Context from IDE:\n<ide_context>\n{context}\n</ide_context>\n\nTask:\n<user_task>\n{task}\n</user_task>"
    try:
        return await instrumented_query(
            capability=capability,
            prompt=full_prompt,
            span_name="mcp.delegate_to_agent",
            attributes={"capability": capability, "context_length": len(context), "task_length": len(task)},
        )
    except AgentNotFoundError as e:
        return f"ERROR: {e}\n\nAvailable capabilities:\n{_list_capabilities()}"
    except AgentExecutionError as e:
        return f"ERROR: {e}"


@mcp.tool()
def list_openclaw_capabilities() -> str:
    """List the OpenClaw agent capabilities currently registered, with their owning agent."""
    return "Registered capabilities (capability: primary_agent):\n" + _list_capabilities()


@mcp.tool()
async def run_openclaw_pipeline(project_name: str, requirement: str) -> str:
    """Run the entire multi-agent OpenClaw pipeline end-to-end for a given project requirement."""
    with logfire.span(
        "mcp.run_pipeline",
        project_name=project_name,
        requirement_length=len(requirement),
        _level="info",
    ):
        from main import main

        await main(project=project_name, step="all", resume=False, auto_yes=True, requirement=requirement)
        return f"Pipeline completed for {project_name}. Artifacts written to disk."


@mcp.tool()
async def plan_and_execute(goal: str) -> str:
    """Creates a plan to achieve a high-level goal and executes all tasks in dependency order."""
    with logfire.span("mcp.plan_and_execute", goal_length=len(goal), _level="info"):
        from openclaw.agents.planner_agent import planner_agent
        from openclaw.registry import instrumented_query

        plan_response = await planner_agent.run(f"Create a plan to achieve this goal: {goal}")
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
    with logfire.span(
        "mcp.modify_existing_code",
        change_description_length=len(change_description),
        codebase_path=codebase_path or "auto-detect",
        _level="info",
    ):
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
    with logfire.span(
        "mcp.scaffold_service",
        service_name=service_name,
        bounded_context=bounded_context,
        _level="info",
    ):
        from main import main

        requirement = requirement or f"Build a {service_name} service for {bounded_context} bounded context."
        await main(project=service_name, step="all", resume=False, auto_yes=True, requirement=requirement)
        return f"Service '{service_name}' scaffolding pipeline completed. Artifacts in generated-app/{service_name}/."


if __name__ == "__main__":
    mcp.run()
