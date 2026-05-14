from dataclasses import dataclass
from pydantic_ai import Agent
from openclaw.config import AgentSettings

@dataclass
class CurrentEventsDeps:
    pass_num: int
    agent_name: str = "current_events"

events_prompt = '''You are a Current Events Agent and a history buff.
Your job is to provide context on current events, blending modern news with historical perspectives.
'''

current_events_agent = Agent(
    AgentSettings.CURRENT_EVENTS_MODEL,
    deps_type=CurrentEventsDeps,
    system_prompt=events_prompt,
    output_type=str,
    defer_model_check=True
)
