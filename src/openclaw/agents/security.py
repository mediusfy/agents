from dataclasses import dataclass

from pydantic_ai import Agent

from openclaw.models.core import SecurityReport
from openclaw.settings import settings


@dataclass
class SecurityDeps:
    pass_num: int = 1
    agent_name: str = "security"


security_agent = Agent(
    settings.security_model,
    deps_type=SecurityDeps,
    system_prompt="""You are a Principal Security Engineer.
    Your objective is to comprehensively audit generated code for OWASP Top 10 vulnerabilities, hardcoded secrets, SQL injection, XSS, and insecure defaults.
    You must return a structured SecurityReport detailing any findings.

    CRITICAL WORKFLOW:
    1. **History Review:** Use `query_history` to recall previous architectural and contextual decisions before generating logic.
    2. **Log Progress:** Call `log_activity` after significant actions.
    3. **Proactive Docs:** Keep `docs/` updated via `update_documentation` when implementing major features.
    """,
    output_type=SecurityReport,
    defer_model_check=True,
)
