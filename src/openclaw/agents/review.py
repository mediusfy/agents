from dataclasses import dataclass
from pydantic_ai import Agent, RunContext

from openclaw.models.core import ReviewResult
from openclaw.settings import settings
from openclaw.models.factory import create_model

@dataclass
class ReviewDependencies:
    blueprint_summary: str
    bounded_contexts: list[str]
    strict_mode: bool = True

review_agent = Agent(
    model=create_model(settings.resolve_model(settings.review_model)),
    output_type=ReviewResult,
    deps_type=ReviewDependencies,
    retries=3,  # Automatically retry if the output doesn't match ReviewResult schema
    defer_model_check=True,
)


@review_agent.system_prompt
def build_qsa_prompt(ctx: RunContext[ReviewDependencies]) -> str:
    """Dynamically builds the system prompt injecting runtime blueprints."""

    strict_clause = (
        "CRITICAL: Strict mode is ENABLED. Any warning must be treated as a hard failure."
        if ctx.deps.strict_mode else
        "NOTE: Strict mode is disabled. Provide warnings for minor infractions."
    )

    return f"""You represent the final governance layer. Your role is to act as a **Qualified Security Assessor (QSA)**. 
You analyze artifacts (Go code, Terraform, Test results) to ensure they meet production-readiness standards. You perform risk-based assessments of the entire system state before milestone approval.

{strict_clause}

### 1. Security (Zero-Trust)
* mTLS must be explicitly enabled everywhere.
* Absolutely NO hardcoded secrets, tokens, or sensitive data in any artifact.

### 2. Architecture Constraints
* Artifacts must perfectly match the approved Event-Driven Blueprint: {ctx.deps.blueprint_summary}
* Artifacts must strictly adhere to these Bounded Contexts: {', '.join(ctx.deps.bounded_contexts)}

### 3. Infrastructure (Terraform)
* NO 'Destroy' actions permitted in production plans.
* ALL modules must be version-pinned (no 'latest' or unversioned branches).

### Output Instructions
Populate your output exactly according to the requested schema. Provide specific line numbers or file names where violations occur to make your review actionable."""