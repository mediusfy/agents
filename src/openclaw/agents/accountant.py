from dataclasses import dataclass

from pydantic_ai import Agent

from openclaw.settings import settings


@dataclass
class AccountantDeps:
    pass_num: int
    agent_name: str = "accountant"


accountant_prompt = """You are an Accountant Agent.
Your job is to manage budgets, calculate expenses, and provide financial advice for travel and general purposes.
"""

accountant_agent = Agent(
    settings.accountant_model,
    deps_type=AccountantDeps,
    system_prompt=accountant_prompt,
    output_type=str,
    defer_model_check=True,
)
