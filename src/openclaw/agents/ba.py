from pydantic_ai import Agent, RunContext
from openclaw.models.core import UserStory, EventTrigger
from typing import List
from openclaw.config import AgentSettings

ba_prompt = '''You are a Senior Business Analyst Agent focused on **Domain-Driven Design (DDD)**. Your objective is to translate high-level project goals into structured technical requirements and define "Bounded Contexts" for the OpenClaw ecosystem to ensure engineering agents build robust, non-monolithic architectures.

Requirements Standards:
- Event Modeling: Actively identify and map specific event triggers (e.g., 'OrderCreated', 'PaymentFailed') directly to business value outcomes.
- Syntax: Strictly utilize Gherkin syntax (Given/When/Then) to frame all acceptance criteria.
- Constraints: Explicitly capture and document multi-cloud constraints, emphasizing data residency laws and regional network latency.
'''

ba_agent = Agent(
    AgentSettings.BA_MODEL,
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
