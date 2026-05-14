from dataclasses import dataclass
from pydantic_ai import Agent
from openclaw.config import AgentSettings

@dataclass
class RegionAnalyzerDeps:
    pass_num: int
    agent_name: str = "region_analyzer"

analyzer_prompt = '''You are a Region Analyzer Agent.
Your job is to analyze geographical regions based on various factors like safety, cost of living, and local attractions.
'''

region_analyzer_agent = Agent(
    AgentSettings.REGION_ANALYZER_MODEL,
    deps_type=RegionAnalyzerDeps,
    system_prompt=analyzer_prompt,
    output_type=str,
    defer_model_check=True
)
