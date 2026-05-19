from pydantic_ai import Agent
from openclaw.registry import registry
from openclaw.planning import Plan

#TODO:  need to load the planner-agent.md
system_prompt = "You are a Planner Agent..."

planner_agent = Agent(
    system_prompt=system_prompt,
    output_type=Plan,
)

registry.register("planner_agent", planner_agent, ["plan"])
