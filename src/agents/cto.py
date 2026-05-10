from dataclasses import dataclass
# pyrefly: ignore [missing-import]
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

CRITICAL WORKFLOW:
1. ALWAYS use the `search_adrs` tool to find past Architecture Decision Records (ADRs) to ensure consistency.
2. If you make a significant new architectural decision, ALWAYS use the `save_adr` tool to document it for the future.

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
    from src.vector_db import vector_db
    results = vector_db.search("adrs", query)
    if not results:
        return f"No ADRs found for query: {query}"
    return "Found past architectural context:\n" + "\n---\n".join(results)

@cto_agent.tool
async def save_adr(ctx: RunContext[OrgContext], decision_id: str, content: str) -> str:
    """Save a new Architecture Decision Record (ADR) to the knowledge base."""
    from src.vector_db import vector_db
    vector_db.add_documents("adrs", [content], [{"id": decision_id}], [decision_id])
    return f"Saved ADR {decision_id} successfully."

agent_bus.register("cto", cto_agent, ["arch_review"])