from pydantic_ai import Agent, RunContext
from src.models.core import SecurityReport
from src.config import AgentSettings

security_agent = Agent(
    AgentSettings.SECURITY_MODEL,
    system_prompt='''You are a Principal Security Engineer.
Your objective is to comprehensively audit generated code for OWASP Top 10 vulnerabilities, hardcoded secrets, SQL injection, XSS, and insecure defaults.
You must return a structured SecurityReport detailing any findings.
''',
    output_type=SecurityReport,
    defer_model_check=True
)


