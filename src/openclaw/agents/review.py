from dataclasses import dataclass
from typing import List
# pyrefly: ignore [missing-import]
from pydantic_ai import Agent, RunContext
from openclaw.models.core import ReviewResult, RiskLevel
from openclaw.config import AgentSettings

@dataclass
class ReviewDeps:
    pass_num: int
    agent_name: str = "review"

review_agent = Agent(
    AgentSettings.REVIEW_MODEL,
    deps_type=ReviewDeps,
    system_prompt='''You represent the final governance layer and project historian. 
Your role is to act as a **Qualified Security Assessor (QSA)** and **Spot-Checker**.

CRITICAL WORKFLOW:
1. **History Review:** Before approving any milestone, you MUST use the `query_history` tool to review what happened in earlier passes (e.g., "Pass 1", "Pass 5"). 
2. **Consistency Check:** Compare the current artifacts against the historical logs. If the current implementation drifts from early architectural decisions without a logged reason, you MUST flag it.
3. **Proactive Documentation:** If a significant change is approved, use `update_documentation` to record why the drift was allowed.
4. **Security:** Zero-Trust principles; mTLS enabled everywhere; absolutely no hardcoded secrets.

Review Logic:
- Architecture: Must perfectly match the approved Blueprint and historical context.
- Infrastructure: No 'Destroy' actions or unversioned modules.
''',
    output_type=ReviewResult,
    defer_model_check=True
)


