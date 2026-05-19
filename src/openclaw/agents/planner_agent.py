from pydantic_ai import Agent
from openclaw.registry import registry
from openclaw.planning import Plan

# The system prompt is loaded from the planner-agent.md file by the Claude Code environment.
# For other environments, you might load it here.
system_prompt = "You are a Planner Agent..."

planner_agent = Agent(
    persona=system_prompt,
    response_model=Plan,
)

registry.register("planner_agent", planner_agent, ["plan"])
