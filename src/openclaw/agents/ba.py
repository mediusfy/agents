from dataclasses import dataclass
# pyrefly: ignore [missing-import]
from pydantic_ai import Agent, RunContext
from openclaw.models.core import UserStory, EventTrigger
from typing import List
from openclaw.config import AgentSettings
from openclaw.a2a import agent_bus

@dataclass
class BADeps:
    pass_num: int
    agent_name: str = "ba"

ba_prompt = '''You are a Senior Business Analyst Agent focused on **Domain-Driven Design (DDD)**. 

CRITICAL WORKFLOW:
1. **Log Progress:** Use the `log_activity` tool after defining user stories or mapping events.
2. **Proactive Docs:** If a new Bounded Context is defined, use `update_documentation` to record it in `docs/Bounded Contexts.md`.
'''

ba_agent = Agent(
    AgentSettings.BA_MODEL,
    deps_type=BADeps,
    system_prompt=ba_prompt,
    output_type=List[UserStory],
    defer_model_check=True
)

extractor = Agent(AgentSettings.BA_MODEL, system_prompt=ba_prompt, output_type=List[UserStory], defer_model_check=True)
event_mapper = Agent(AgentSettings.BA_MODEL, system_prompt=ba_prompt, output_type=List[EventTrigger], defer_model_check=True)

@ba_agent.tool
async def define_user_stories(ctx: RunContext[str], raw_requirements: str) -> List[UserStory]:
    """Converts raw text requirements into structured UserStory models using an LLM."""
    res = await extractor.run(f"Extract user stories from: {raw_requirements}")
    return res.data

@ba_agent.tool
async def map_event_triggers(ctx: RunContext[str], story_id: str, gherkin: str) -> List[EventTrigger]:
    """Identifies specific events necessary for the Go backend and QA automation pipelines."""
    res = await event_mapper.run(f"Identify event triggers for story {story_id} with gherkin: {gherkin}")
    return res.data

agent_bus.register("ba", ba_agent, ["requirements_analysis"], lambda: BADeps(pass_num=1))


