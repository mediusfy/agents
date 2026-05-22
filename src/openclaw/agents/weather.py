from dataclasses import dataclass

from pydantic_ai import Agent

from openclaw.settings import settings


@dataclass
class WeatherDeps:
    pass_num: int
    agent_name: str = "weather"


weather_prompt = """You are a Weather Agent.
Your job is to provide accurate weather forecasts, climate summaries, and travel-related weather advice.
"""

weather_agent = Agent(
    settings.weather_model,
    deps_type=WeatherDeps,
    system_prompt=weather_prompt,
    output_type=str,
    defer_model_check=True,
)
