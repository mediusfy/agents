"""Centralized configuration via pydantic-settings.

All environment variables are validated and typed here.
Usage:
    from openclaw.settings import settings
    settings.ba_model       # "gpt-4o-mini" by default
    settings.max_retries    # 2 by default
"""

from typing import Optional
from pathlib import Path
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    #  LLM Provider API Keys
    openai_api_key: Optional[str] = None
    anthropic_api_key: Optional[str] = None
    gemini_api_key: Optional[str] = None

    # Agent Model Overrides
    ba_model: str = "gpt-4o-mini"
    backend_model: str = "claude-sonnet-4-20250514"
    frontend_model: str = "gpt-4o"
    test_model: str = "gpt-4o-mini"
    sre_model: str = "gemini-2.0-flash"
    review_model: str = "claude-sonnet-4-20250514"
    database_model: str = "gpt-4o-mini"
    devops_model: str = "gpt-4o-mini"
    docs_model: str = "gpt-4o-mini"
    security_model: str = "claude-sonnet-4-20250514"
    ux_model: str = "claude-sonnet-4-20250514"
    cto_model: str = "claude-sonnet-4-20250514"

    holiday_planner_model: str = "gpt-4o"
    region_analyzer_model: str = "gpt-4o"
    asymmetric_reviewer_model: str = "gpt-4o"
    current_events_model: str = "gpt-4o"
    weather_model: str = "gpt-4o-mini"
    accountant_model: str = "gpt-4o"
    price_analyst_model: str = "gemini-2.0-pro"
    market_shark_model: str = "gemini-2.0-pro"
    crypto_oracle_model: str = "gemini-2.0-pro"

    # ── Pipeline Configuration
    output_dir: Path = Path("./generated-app")
    max_retries: int = 2
    max_concurrent_llm_calls: int = 5
    checkpoint_dir: Path = Path("./.claw-checkpoints")
    vector_db_dir: Path = Path("./.claw-vectordb")
    agent_config_path: str = ""

    # ── Pipeline Runtime
    requirement: Optional[str] = None


settings = Settings()
