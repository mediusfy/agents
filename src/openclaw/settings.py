"""Centralized configuration via pydantic-settings.

All environment variables are validated and typed here.
Usage:
    from openclaw.settings import settings
    settings.ba_model       # "deepseek-reasoner" by default
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

    openai_api_key: str | None = None
    anthropic_api_key: str | None = None
    gemini_api_key: str | None = None
    deepseek_api_key: str | None = None
    logfire_token: str | None = None
    logfire_api_key: str | None = None

    database_url: str | None = None

    model_provider: str | None = "deepseek"

    redis_iris_url: str | None = None
    redis_iris_store_id: str | None = None
    redis_iris_token: str | None = None

    # Agent Model Overrides
    # NOTE: When model_provider is set (e.g. "deepseek"), resolve_model() remaps ALL
    # model names through the provider. So these defaults serve as capability tiers
    # and are resolved at runtime — actual model used depends on model_provider and
    # the resolve_model mapping below.
    ba_model: str = "deepseek-reasoner"
    backend_model: str = "claude-sonnet-4-20250514"
    frontend_model: str = "gpt-4o"
    test_model: str = "deepseek-reasoner"
    sre_model: str = "gemini-2.0-flash"
    review_model: str = "claude-sonnet-4-20250514"
    database_model: str = "deepseek-reasoner"
    devops_model: str = "deepseek-reasoner"
    docs_model: str = "deepseek-reasoner"
    security_model: str = "claude-sonnet-4-20250514"
    ux_model: str = "claude-sonnet-4-20250514"
    cto_model: str = "claude-sonnet-4-20250514"

    holiday_planner_model: str = "gpt-4o"
    region_analyzer_model: str = "gpt-4o"
    asymmetric_reviewer_model: str = "gpt-4o"
    current_events_model: str = "gpt-4o"
    weather_model: str = "deepseek-reasoner"
    accountant_model: str = "gpt-4o"
    price_analyst_model: str = "gemini-2.0-pro"
    market_shark_model: str = "gemini-2.0-pro"
    crypto_oracle_model: str = "gemini-2.0-pro"

    # Pipeline Configuration
    output_dir: Path = Path("./generated-app")
    max_retries: int = 3  # Autonomous Remediation Loop: max retries before escalating to Lead Orchestrator
    max_concurrent_llm_calls: int = 5
    checkpoint_dir: Path = Path("./.claw-checkpoints")
    vector_db_dir: Path = Path("./.claw-vectordb")

    go_version: str = "1.26"

    def resolve_model(self, model_name: str) -> str:
        """Ensure the model name is a valid pydantic_ai model spec.

        PROVIDER CONSISTENCY ENFORCEMENT:
        When MODEL_PROVIDER is set, ALL model names are remapped through that
        single provider. This guarantees uniform reasoning capability and output
        structure across all sub-agents — critical when agents hand off JSON
        payloads via MCP.

        When MODEL_PROVIDER is None, each model name is used as-is with provider
        prefixes added only for models pydantic_ai doesn't know natively.

        Behavior:
        - provider="deepseek": all models → deepseek:deepseek-reasoner
        - provider="gemini": all models → gemini:gemini-2.0-flash
        - provider="openai": all models → openai:gpt-4o
        - None: pass through with prefix for deepseek-* models only
        """
        provider = self.model_provider
        if provider:
            if provider == "deepseek":
                return f"deepseek:{model_name}" if ":" not in model_name else model_name
            if provider == "gemini":
                # All agents use gemini-2.0-flash for consistency
                return "gemini:gemini-2.0-flash"
            if provider == "vertexai":
                # Use Google Cloud ADC (OAuth) instead of AI Studio API keys
                return "vertexai:gemini-2.0-flash"
            if provider == "openai":
                return "openai:gpt-4o"
            # Generic provider — pass through with prefix if needed
            if ":" in model_name:
                return model_name
            return f"{provider}:{model_name}"

        # No provider override — add prefixes for known non-native models
        if ":" in model_name:
            return model_name
        if model_name.startswith("deepseek-"):
            return f"deepseek:{model_name}"
        # gpt-*, claude-*, gemini-* are known natively by pydantic_ai
        return model_name


settings = Settings()
