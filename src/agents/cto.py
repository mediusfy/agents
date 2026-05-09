from dataclasses import dataclass
from pydantic_ai import Agent, RunContext
from src.models.core import AgentAdvice
from src.config import AgentSettings
from src.a2a import agent_bus

@dataclass
class OrgContext:
    tech_stack: list[str]
    compliance_tier: str  # e.g., "SOC2", "HIPAA", "Standard"
    monthly_cloud_budget: float

cto_prompt = '''You are the Chief Technology Officer (CTO) agent. You are sharp, highly experienced, and possess deep architectural foresight.
Your job is to review product requirements and user stories BEFORE any code is written, to identify bottlenecks, scale issues, and mistakes before they occur.
Provide strict architectural constraints and strategic advice that the engineering agents (Backend/Frontend) must follow.

If a requirement is fundamentally flawed, unscalable, or violates our compliance tier, flag it in the bottlenecks and set `approved_to_proceed` to False to force a revision.
'''

cto_agent = Agent(
    AgentSettings.REVIEW_MODEL,
    deps_type=OrgContext,
    system_prompt=cto_prompt,
    output_type=AgentAdvice,
    defer_model_check=True
)

@cto_agent.system_prompt
def inject_org_constraints(ctx: RunContext[OrgContext]) -> str:
    return f"""
    Current Organizational Constraints:
    - Approved Tech Stack: {', '.join(ctx.deps.tech_stack)}
    - Compliance Requirement: {ctx.deps.compliance_tier}
    - Monthly Cloud Budget: ${ctx.deps.monthly_cloud_budget:,.2f}
    
    Do not approve architectures that introduce unapproved languages/frameworks or risk breaching our compliance tier.
    """


@cto_agent.tool
async def search_adrs(ctx: RunContext[OrgContext], query: str) -> str:
    """Search existing Architecture Decision Records (ADRs) to ensure new advice doesn't contradict past rulings."""
    # TODO: return await vector_db.search_adrs(query)
    return f"Simulated ADR search results for: {query}"


agent_bus.register("cto", cto_agent, ["arch_review"])