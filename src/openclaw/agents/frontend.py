from pydantic import BaseModel
from pydantic_ai import Agent, UsageLimits, RunContext

from openclaw.models.core import Artifact
from openclaw.models.factory import create_model
from openclaw.settings import settings

frontend_prompt = """You are a Lead Frontend Engineer building Vue 3 interfaces using the Composition API and TSX. You must ensure every interactive element is strictly **WCAG 2.1 compliant** and includes a unique data-testid attribute to facilitate flawless automated simulation by testing agents.

Technical Priorities:
- Atomic Design: Enforce component modularity and reusability across the OpenClaw Agent SDK.
- State Management: Architect the UI to function as a seamless, real-time reflection of the backend event bus using Vue's reactivity system.
- Event Handling: Implement robust WebSocket or Server-Sent Events (SSE) logic, including automatic reconnection strategies and state reconciliation.
"""

frontend_agent = Agent(
    create_model(settings.resolve_model(settings.frontend_model)),
    system_prompt=frontend_prompt,
    output_type=Artifact,
    defer_model_check=True,
    retries=5,
)


class ComponentOutput(BaseModel):
    code: str


# Text-first agent: reasoner generates code as free text (no result_type constraint)
component_gen = Agent(
    create_model(settings.resolve_model(settings.frontend_model)),
    system_prompt=frontend_prompt,
    defer_model_check=True,
    retries=5,
)

# Structured output agent: deepseek-chat wraps raw code into ComponentOutput
_component_struct = Agent(
    create_model('deepseek:deepseek-chat'),
    system_prompt="You format generated code into the requested structure. Return ONLY valid JSON.",
    output_type=ComponentOutput,
    defer_model_check=True,
    retries=3,
)


@frontend_agent.tool
async def create_component(ctx: RunContext[str], component_name: str, requirements: str, test_id: str) -> str:
    """Calls model to generate a production-ready Vue 3 TSX component with: WCAG 2.1 ARIA labels, data-testid attribute, TypeScript props interface, Tailwind/CSS module styling, proper event handler typing."""
    # Step 1: reasoner generates code as free text
    raw = await component_gen.run(
        f"Generate Vue 3 TSX component {component_name} using Composition API with requirements: {requirements}. Use data-testid={test_id}.",
        usage_limits=UsageLimits(request_limit=500),
    )
    # Step 2: deepseek-chat structures it into ComponentOutput
    structured = await _component_struct.run(
        f"Wrap this generated code: {raw.data}",
        usage_limits=UsageLimits(request_limit=500),
    )
    return structured.output.code
