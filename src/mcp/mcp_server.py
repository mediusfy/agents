from mcp.server.fastmcp import FastMCP
import subprocess
import json
import uuid
import asyncio
from openclaw.checkpoint import CheckpointManager

from openclaw.agents.non_technical.holiday_planner import holiday_planner_agent, HolidayPlannerDeps
from openclaw.agents.region_analyzer import region_analyzer_agent, RegionAnalyzerDeps
from openclaw.agents.asymmetric_reviewer import asymmetric_reviewer_agent, AsymmetricReviewerDeps
from openclaw.agents.current_events import current_events_agent, CurrentEventsDeps
from openclaw.agents.weather import weather_agent, WeatherDeps
from openclaw.agents.accountant import accountant_agent, AccountantDeps

mcp = FastMCP("OpenClaw Orchestrator")

def create_agent_runner(agent, deps_class, docstring):
    """A factory function to create an MCP tool for running an agent."""

    # This is the actual function that will be decorated as a tool
    async def agent_runner(request: str) -> str:
        deps = deps_class(pass_num=1)
        result = await agent.run(request, deps=deps)
        return result.data

    # Set the docstring for the tool's help text
    agent_runner.__doc__ = docstring
    # Give the function a unique name
    agent_runner.__name__ = f"run_{agent.name.lower().replace(' ', '_')}" # Assumes agent has a .name attribute

    # Decorate and return the newly created function
    return mcp.tool()(agent_runner)

run_holiday_planner = create_agent_runner(
    holiday_planner_agent, HolidayPlannerDeps, "Invokes the Holiday Planner Agent."
)
run_region_analyzer = create_agent_runner(
    region_analyzer_agent, RegionAnalyzerDeps, "Invokes the Region Analyzer Agent."
)
run_asymmetric_reviewer = create_agent_runner(
    asymmetric_reviewer_agent, AsymmetricReviewerDeps, "Invokes the Asymmetric Reviewer Agent (law & corporate tricks for travel savings)."
)
run_current_events = create_agent_runner(
    current_events_agent, CurrentEventsDeps, "Invokes the Current Events Agent (history buff)."
)
run_weather = create_agent_runner(
    weather_agent, WeatherDeps, "Invokes the Weather Agent."
)
run_accountant = create_agent_runner(
    accountant_agent, AccountantDeps, "Invokes the Accountant Agent."
)


@mcp.tool()
def scaffold_and_build_service(service_name: str, bounded_context: str) -> str:
    """
    Triggers the background OpenClaw/Dagster pipeline to build a new service.
    Use this tool whenever the user asks to build or scaffold a new backend service.
    """
    run_id = str(uuid.uuid4())

    run_config = {
        "ops": {
            "pre_coding_hook": {"config": {"run_id": run_id, "service_name": service_name, "bounded_context": bounded_context}},
            "generate_go_code": {"config": {"run_id": run_id, "service_name": service_name, "bounded_context": bounded_context}},
            "post_coding_hook": {"config": {"run_id": run_id, "service_name": service_name, "bounded_context": bounded_context}}
        }
    }

    with open(f"/tmp/{run_id}_config.json", "w") as f:
        json.dump(run_config, f)

    try:
        subprocess.run([
            "dagster", "job", "execute",
            "-f", "openclaw/dagster_defs.py", 
            "-c", f"/tmp/{run_id}_config.json"
        ], check=True, capture_output=True, text=True)

        ckpt = CheckpointManager(project_name=service_name, run_id=run_id)
        final_state = ckpt.load("03_post_hook_verified")

        if final_state:
            return f"Success! Pipeline finished. Generated Code Artifacts:\n{final_state.data.get('generated_artifact')}"
        else:
            return "Pipeline ran, but could not load the final checkpoint. Check Dagster logs."

    except subprocess.CalledProcessError as e:
        return f"Pipeline failed during execution. Error logs:\n{e.stderr}"

@mcp.tool()
async def run_holiday_planner(request: str) -> str:
    """Invokes the Holiday Planner Agent."""
    deps = HolidayPlannerDeps(pass_num=1)
    result = await holiday_planner_agent.run(request, deps=deps)
    return result.data

@mcp.tool()
async def run_region_analyzer(request: str) -> str:
    """Invokes the Region Analyzer Agent."""
    deps = RegionAnalyzerDeps(pass_num=1)
    result = await region_analyzer_agent.run(request, deps=deps)
    return result.data

@mcp.tool()
async def run_asymmetric_reviewer(request: str) -> str:
    """Invokes the Asymmetric Reviewer Agent (law & corporate tricks for travel savings)."""
    deps = AsymmetricReviewerDeps(pass_num=1)
    result = await asymmetric_reviewer_agent.run(request, deps=deps)
    return result.data

@mcp.tool()
async def run_current_events(request: str) -> str:
    """Invokes the Current Events Agent (history buff)."""
    deps = CurrentEventsDeps(pass_num=1)
    result = await current_events_agent.run(request, deps=deps)
    return result.data

@mcp.tool()
async def run_weather(request: str) -> str:
    """Invokes the Weather Agent."""
    deps = WeatherDeps(pass_num=1)
    result = await weather_agent.run(request, deps=deps)
    return result.data

@mcp.tool()
async def run_accountant(request: str) -> str:
    """Invokes the Accountant Agent."""
    deps = AccountantDeps(pass_num=1)
    result = await accountant_agent.run(request, deps=deps)
    return result.data

if __name__ == "__main__":
    mcp.run()