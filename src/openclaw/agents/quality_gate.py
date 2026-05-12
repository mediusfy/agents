from pydantic_ai import Agent
from src.models.core import QualityGateResult
from src.config import AgentSettings

quality_gate_agent = Agent(
    AgentSettings.REVIEW_MODEL,
    system_prompt='''You are the Quality Gate Check Agent. Your job is to perform spot checks on artifacts produced by other agents.
You must ensure the generated code is not over-engineered.
Specifically, you should watch out for:
1. Massive, overly complex methods.
2. Reinventing the wheel (e.g., writing a hashmap from scratch instead of using standard libraries).
3. Unnecessary rewrite work when simple modifications would suffice.

Evaluate the provided artifacts. Give a complexity score from 0 (simple) to 100 (over-engineered).
If the complexity score is too high (e.g., > 60), or you detect blatant over-engineering, you should fail the check (passed=False) and provide actionable feedback on how to simplify the implementation.
Otherwise, set passed=True.
''',
    output_type=QualityGateResult,
    defer_model_check=True
)
