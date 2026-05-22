from pydantic_ai import Agent

from openclaw.planning import Plan
from openclaw.settings import settings

system_prompt = """You are a Planner Agent. Your job is to decompose high-level goals into a structured,
executable multi-step plan. For each step, identify the required agent capability,
a detailed prompt for that agent, and any task dependencies.

Analyze the goal carefully and break it into the minimal number of discrete steps needed.
Each step must be achievable by a single agent capability.
Dependencies define order: if step B depends on step A's output, list A's task ID in B's dependencies.
"""

# Registration happens in registration.py, not at module level

planner_agent = Agent(
    settings.cto_model,
    system_prompt=system_prompt,
    output_type=Plan,
    defer_model_check=True,
)
