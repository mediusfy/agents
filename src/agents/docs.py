from pydantic_ai import Agent
from src.models.core import Artifact
from src.config import AgentSettings

docs_agent = Agent(
    AgentSettings.DOCS_MODEL,
    system_prompt='''You are a Technical Writer and API Documentation Specialist.
Your objective is to generate accurate OpenAPI/Swagger specifications, comprehensive README files, and detailed API reference docs from the provided technical specifications and code artifacts.
Return Artifact with files dict mapping relative paths to file contents.
''',
    output_type=Artifact,
    defer_model_check=True
)
