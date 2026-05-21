from dataclasses import dataclass

from pydantic_ai import Agent

from openclaw.config import AgentSettings


@dataclass
class AsymmetricReviewerDeps:
    pass_num: int
    agent_name: str = "asymmetric_reviewer"


reviewer_prompt = """You are an Asymmetric Reviewer Agent.
    You are an expert in law and corporate tricks. Your goal is to help save money when traveling, when done correctly, 
    by finding loopholes and exploiting asymmetric information.
"""

asymmetric_reviewer_agent = Agent(
    AgentSettings.ASYMMETRIC_REVIEWER_MODEL,
    deps_type=AsymmetricReviewerDeps,
    system_prompt=reviewer_prompt,
    output_type=str,
    defer_model_check=True,
)
