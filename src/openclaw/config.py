"""Backward-compatible configuration re-export.

New code should import directly from openclaw.settings:
    from openclaw.settings import settings
"""

from openclaw.settings import settings as _settings


class AgentSettings:
    BA_MODEL = _settings.ba_model
    BACKEND_MODEL = _settings.backend_model
    FRONTEND_MODEL = _settings.frontend_model
    TEST_MODEL = _settings.test_model
    SRE_MODEL = _settings.sre_model
    REVIEW_MODEL = _settings.review_model
    DATABASE_MODEL = _settings.database_model
    DEVOPS_MODEL = _settings.devops_model
    DOCS_MODEL = _settings.docs_model
    SECURITY_MODEL = _settings.security_model
    UX_MODEL = _settings.ux_model
    CTO_MODEL = _settings.cto_model

    HOLIDAY_PLANNER_MODEL = _settings.holiday_planner_model
    REGION_ANALYZER_MODEL = _settings.region_analyzer_model
    ASYMMETRIC_REVIEWER_MODEL = _settings.asymmetric_reviewer_model
    CURRENT_EVENTS_MODEL = _settings.current_events_model
    WEATHER_MODEL = _settings.weather_model
    ACCOUNTANT_MODEL = _settings.accountant_model
    PRICE_ANALYST_MODEL = _settings.price_analyst_model
    MARKET_SHARK_MODEL = _settings.market_shark_model
    CRYPTO_ORACLE_MODEL = _settings.crypto_oracle_model

    OUTPUT_DIR = str(_settings.output_dir)
    MAX_RETRIES = _settings.max_retries
    MAX_CONCURRENT_LLM_CALLS = _settings.max_concurrent_llm_calls
    AGENT_CONFIG_PATH = _settings.agent_config_path
    CHECKPOINT_DIR = str(_settings.checkpoint_dir)
