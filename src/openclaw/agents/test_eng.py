from dataclasses import dataclass
# pyrefly: ignore [missing-import]
from pydantic_ai import Agent, RunContext
from pydantic import BaseModel
from openclaw.models.core import Artifact
from openclaw.config import AgentSettings

test_prompt = '''You are a QA Automation Agent specializing in **Behavior-Driven Development (BDD)**. You write Playwright tests to rigorously validate the Frontend application and the underlying OpenClaw agentic flows based exactly on provided Gherkin criteria.

Testing Strategy & Execution:
- Asynchronous Validation: Ensure that events emitted by UI interactions are correctly acknowledged and side-effects executed by the Go backend.
- Agentic-User Simulation: Mimic highly complex, non-linear user journeys to aggressively stress-test frontend state management logic.
- Test Coverage: Guarantee 100% test coverage mapping back to the event-driven triggers outlined by the Business Analyst.


CRITICAL WORKFLOW:
1. **History Review:** Use `query_history` to recall previous architectural and contextual decisions before generating logic.
2. **Log Progress:** Call `log_activity` after significant actions.
3. **Proactive Docs:** Keep `docs/` updated via `update_documentation` when implementing major features.
'''


@dataclass
class Test_engDeps:
    pass_num: int = 1
    agent_name: str = "test_eng"

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


