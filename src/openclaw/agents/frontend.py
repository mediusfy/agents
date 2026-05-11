from dataclasses import dataclass
# pyrefly: ignore [missing-import]
from pydantic_ai import Agent, RunContext
from openclaw.models.core import Artifact
from openclaw.config import AgentSettings
from pydantic import BaseModel
from openclaw.a2a import agent_bus

frontend_prompt = '''You are a Lead Frontend Engineer building Vue 3 interfaces using the Composition API and TSX. You must ensure every interactive element is strictly **WCAG 2.1 compliant** and includes a unique data-testid attribute to facilitate flawless automated simulation by testing agents.

Technical Priorities:
- Atomic Design: Enforce component modularity and reusability across the OpenClaw Agent SDK.
- State Management: Architect the UI to function as a seamless, real-time reflection of the backend event bus using Vue's reactivity system.
- Event Handling: Implement robust WebSocket or Server-Sent Events (SSE) logic, including automatic reconnection strategies and state reconciliation.


CRITICAL WORKFLOW:
1. **History Review:** Use `query_history` to recall previous architectural and contextual decisions before generating logic.
2. **Log Progress:** Call `log_activity` after significant actions.
3. **Proactive Docs:** Keep `docs/` updated via `update_documentation` when implementing major features.
'''


@dataclass
class FrontendDeps:
    pass_num: int = 1
    agent_name: str = "frontend"

frontend_agent = Agent(
    AgentSettings.FRONTEND_MODEL,
    deps_type=FrontendDeps,
    system_prompt=frontend_prompt,
    output_type=Artifact,
    defer_model_check=True
)

class ComponentOutput(BaseModel):
    code: str

component_gen = Agent(AgentSettings.FRONTEND_MODEL, system_prompt=frontend_prompt, output_type=ComponentOutput, defer_model_check=True)

@frontend_agent.tool
async def create_component(ctx: RunContext[str], component_name: str, requirements: str, test_id: str) -> str:
    """Calls model to generate a production-ready Vue 3 TSX component with: WCAG 2.1 ARIA labels, data-testid attribute, TypeScript props interface, Tailwind/CSS module styling, proper event handler typing."""
    res = await component_gen.run(f"Generate Vue 3 TSX component {component_name} using Composition API with requirements: {requirements}. Use data-testid={test_id}.")
    return res.data.code

agent_bus.register("frontend", frontend_agent, ["frontend_dev", "vue_components"], lambda: FrontendDeps())
