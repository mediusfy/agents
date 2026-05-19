from mcp.server.fastmcp import FastMCP
import subprocess
import json
import uuid
from openclaw.checkpoint import CheckpointManager

from openclaw.agents.non_technical.holiday_planner import holiday_planner_agent, HolidayPlannerDeps
from openclaw.agents.region_analyzer import region_analyzer_agent, RegionAnalyzerDeps
from openclaw.agents.asymmetric_reviewer import asymmetric_reviewer_agent, AsymmetricReviewerDeps
from openclaw.agents.current_events import current_events_agent, CurrentEventsDeps
from openclaw.agents.weather import weather_agent, WeatherDeps
from openclaw.agents.accountant import accountant_agent, AccountantDeps

mcp = FastMCP("OpenClaw Orchestrator")

def create_agent_runner(agent, deps_class, tool_name: str, docstring: str):
    """A factory function to create an MCP tool for running an agent."""
    async def agent_runner(request: str) -> str:
        deps = deps_class(pass_num=1)
        result = await agent.run(request, deps=deps)
        return result.data

    agent_runner.__doc__ = docstring
    agent_runner.__name__ = tool_name

    return mcp.tool(name=tool_name)(agent_runner)

run_holiday_planner = create_agent_runner(
    holiday_planner_agent, HolidayPlannerDeps, "run_holiday_planner", "Invokes the Holiday Planner Agent."
)
run_region_analyzer = create_agent_runner(
    region_analyzer_agent, RegionAnalyzerDeps, "run_region_analyzer", "Invokes the Region Analyzer Agent."
)
run_asymmetric_reviewer = create_agent_runner(
    asymmetric_reviewer_agent, AsymmetricReviewerDeps, "run_asymmetric_reviewer", "Invokes the Asymmetric Reviewer Agent (law & corporate tricks for travel savings)."
)
run_current_events = create_agent_runner(
    current_events_agent, CurrentEventsDeps, "run_current_events", "Invokes the Current Events Agent (history buff)."
)
run_weather = create_agent_runner(
    weather_agent, WeatherDeps, "run_weather", "Invokes the Weather Agent."
)
run_accountant = create_agent_runner(
    accountant_agent, AccountantDeps, "run_accountant", "Invokes the Accountant Agent."
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
            artifact_summary = "\n".join(
                f"  - {art.agent_name}: {', '.join(art.files.keys())}"
                for art in final_state.artifacts
            ) if final_state.artifacts else "  (no artifacts)"
            return f"Success! Pipeline finished. Generated Code Artifacts:\n{artifact_summary}"
        else:
            return "Pipeline ran, but could not load the final checkpoint. Check Dagster logs."

    except subprocess.CalledProcessError as e:
        return f"Pipeline failed during execution. Error logs:\n{e.stderr}"

if __name__ == "__main__":
    print("Starting MCP server...")
    mcp.run()