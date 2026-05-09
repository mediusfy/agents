from pydantic_ai import Agent, RunContext
from pydantic import BaseModel
from src.models.core import Artifact
from src.config import AgentSettings

test_prompt = '''You are a QA Automation Agent specializing in **Behavior-Driven Development (BDD)**. You write Playwright tests to rigorously validate the Frontend application and the underlying OpenClaw agentic flows based exactly on provided Gherkin criteria.

Testing Strategy & Execution:
- Asynchronous Validation: Ensure that events emitted by UI interactions are correctly acknowledged and side-effects executed by the Go backend.
- Agentic-User Simulation: Mimic highly complex, non-linear user journeys to aggressively stress-test frontend state management logic.
- Test Coverage: Guarantee 100% test coverage mapping back to the event-driven triggers outlined by the Business Analyst.
'''

test_agent = Agent(
    AgentSettings.TEST_MODEL,
    system_prompt=test_prompt,
    output_type=Artifact,
    defer_model_check=True
)

from pydantic import BaseModel
class TestOutput(BaseModel):
    code: str

test_gen = Agent(AgentSettings.TEST_MODEL, system_prompt=test_prompt, output_type=TestOutput, defer_model_check=True)

@test_agent.tool
async def generate_test_suite(ctx: RunContext[str], user_story_gherkin: str) -> str:
    """Converts Gherkin to Playwright TypeScript tests: data-testid selectors, async/await, page object pattern, backend event validation."""
    res = await test_gen.run(f"Write a playwright test for {user_story_gherkin}.")
    return res.data.code


