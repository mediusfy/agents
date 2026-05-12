from dataclasses import dataclass
from pydantic_ai import Agent, RunContext
from openclaw.config import AgentSettings
from openclaw.a2a import agent_bus

@dataclass
class HolidayPlannerDeps:
    pass_num: int
    agent_name: str = "holiday_planner"

planner_prompt = '''You are a Holiday Planner Agent.
Your job is to coordinate travel plans, organize itineraries, and ensure a seamless travel experience for the user.
'''

holiday_planner_agent = Agent(
    AgentSettings.HOLIDAY_PLANNER_MODEL,
    deps_type=HolidayPlannerDeps,
    system_prompt=planner_prompt,
    output_type=str,
    defer_model_check=True
)

agent_bus.register("holiday_planner", holiday_planner_agent, ["planning"], lambda: HolidayPlannerDeps(pass_num=1))
