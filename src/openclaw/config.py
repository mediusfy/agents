from pydantic_settings import BaseSettings
from .settings import settings as _settings


class WorkerSettings(BaseSettings):
    """Configuration for the OpenClaw worker process."""

    # Maximum number of times the agent can attempt to correct a failed task.
    max_correction_attempts: int = 3
    # Time in seconds to wait for a new task before checking for shutdown.
    task_consume_timeout: float = 1.0


class AgentSettings:
    """Per-agent model selection (reads from Settings/env)."""

    ACCOUNTANT_MODEL = _settings.accountant_model
    ASYMMETRIC_REVIEWER_MODEL = _settings.asymmetric_reviewer_model
    BACKEND_MODEL = _settings.backend_model
    BA_MODEL = _settings.ba_model
    CRYPTO_ORACLE_MODEL = _settings.crypto_oracle_model
    CTO_MODEL = _settings.cto_model
    CURRENT_EVENTS_MODEL = _settings.current_events_model
    DATABASE_MODEL = _settings.database_model
    DEVOPS_MODEL = _settings.devops_model
    DOCS_MODEL = _settings.docs_model
    FRONTEND_MODEL = _settings.frontend_model
    HOLIDAY_PLANNER_MODEL = _settings.holiday_planner_model
    MARKET_SHARK_MODEL = _settings.market_shark_model
    PRICE_ANALYST_MODEL = _settings.price_analyst_model
    REGION_ANALYZER_MODEL = _settings.region_analyzer_model
    REVIEW_MODEL = _settings.review_model
    SECURITY_MODEL = _settings.security_model
    SRE_MODEL = _settings.sre_model
    TEST_MODEL = _settings.test_model
    UX_MODEL = _settings.ux_model
    WEATHER_MODEL = _settings.weather_model


settings = WorkerSettings()
