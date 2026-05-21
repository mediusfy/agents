from dataclasses import dataclass

from pydantic_ai import Agent

from openclaw.config import AgentSettings
from openclaw.models.core import AgentAdvice


@dataclass
class OrgContext:
    tech_stack: list[str]
    compliance_tier: str
    monthly_cloud_budget: float


cto_agent = Agent(
    AgentSettings.CTO_MODEL,
    system_prompt="""You are the Chief Technology Officer (CTO) agent. You are sharp, highly experienced, and possess deep architectural foresight.
    Your job is to review product requirements and user stories BEFORE any code is written, to identify bottlenecks, scale issues, and mistakes before they occur.
    Provide strict architectural constraints and strategic advice that the engineering agents (Backend/Frontend) must follow.
    If a requirement is fundamentally flawed or unscalable, flag it in the bottlenecks and optionally set approved_to_proceed to False to force a revision.
    """,
    output_type=AgentAdvice,
    defer_model_check=True,
)
