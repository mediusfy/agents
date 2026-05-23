"""Centralized configuration via pydantic-settings.

All environment variables are validated and typed here.
Usage:
    from openclaw.settings import settings
    settings.ba_model       # "deepseek-chat" by default
    settings.max_retries    # 2 by default
"""

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
    openai_api_key: str | None = None
    anthropic_api_key: str | None = None
    gemini_api_key: str | None = None
    deepseek_api_key: str | None = None

    # Provider override — set to "deepseek" to use DeepSeek for all agents.
    # When set, all model names are automatically prefixed with "deepseek:".
    model_provider: str | None = "deepseek"

    # Redis IRIS Memory Backend
    redis_iris_url: str | None = None
    redis_iris_store_id: str | None = None
    redis_iris_token: str | None = None

    # Agent Model Overrides
    ba_model: str = "deepseek-chat"
    backend_model: str = "claude-sonnet-4-20250514"
    frontend_model: str = "gpt-4o"
    test_model: str = "deepseek-chat"
    sre_model: str = "gemini-2.0-flash"
    review_model: str = "claude-sonnet-4-20250514"
    database_model: str = "deepseek-chat"
    devops_model: str = "deepseek-chat"
    docs_model: str = "deepseek-chat"
    security_model: str = "claude-sonnet-4-20250514"
    ux_model: str = "claude-sonnet-4-20250514"
    cto_model: str = "claude-sonnet-4-20250514"

    holiday_planner_model: str = "gpt-4o"
    region_analyzer_model: str = "gpt-4o"
    asymmetric_reviewer_model: str = "gpt-4o"
    current_events_model: str = "gpt-4o"
    weather_model: str = "deepseek-chat"
    accountant_model: str = "gpt-4o"
    price_analyst_model: str = "gemini-2.0-pro"
    market_shark_model: str = "gemini-2.0-pro"
    crypto_oracle_model: str = "gemini-2.0-pro"

    # Pipeline Configuration
    output_dir: Path = Path("./generated-app")
    max_retries: int = 2
    max_concurrent_llm_calls: int = 5
    checkpoint_dir: Path = Path("./.claw-checkpoints")
    vector_db_dir: Path = Path("./.claw-vectordb")

    def resolve_model(self, model_name: str) -> str:
        """Apply the model_provider prefix if configured.

        When MODEL_PROVIDER=deepseek, 'gpt-4o-mini' becomes 'deepseek:deepseek-chat'.
        Maps common model families to their DeepSeek equivalents.
        """
        provider = self.model_provider
        if not provider:
            return model_name
        if ":" in model_name:
            return model_name  # Already has a provider prefix
        if provider == "deepseek":
            # Map common models to DeepSeek equivalents
            mapping = {
                "gpt-4o-mini": "deepseek-chat",
                "deepseek-chat": "deepseek-chat",
                "gpt-4o": "deepseek-chat",
                "gpt-4": "deepseek-chat",
                "claude-sonnet-4-20250514": "deepseek-chat",
                "claude-3": "deepseek-chat",
                "gemini-2.0-flash": "deepseek-chat",
                "gemini-2.0-pro": "deepseek-chat",
            }
            resolved = mapping.get(model_name, "deepseek-chat")
            return f"{provider}:{resolved}"
        return model_name


settings = Settings()