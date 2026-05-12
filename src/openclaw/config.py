import os

class AgentSettings:
    BA_MODEL = os.getenv("BA_MODEL", "gpt-4o-mini")
    BACKEND_MODEL = os.getenv("BACKEND_MODEL", "claude-sonnet-4-20250514")
    FRONTEND_MODEL = os.getenv("FRONTEND_MODEL", "gpt-4o")
    TEST_MODEL = os.getenv("TEST_MODEL", "gpt-4o-mini")
    SRE_MODEL = os.getenv("SRE_MODEL", "gemini-2.0-flash")
    REVIEW_MODEL = os.getenv("REVIEW_MODEL", "claude-sonnet-4-20250514")
    DATABASE_MODEL = os.getenv("DATABASE_MODEL", "gpt-4o-mini")
    DEVOPS_MODEL = os.getenv("DEVOPS_MODEL", "gpt-4o-mini")
    DOCS_MODEL = os.getenv("DOCS_MODEL", "gpt-4o-mini")
    SECURITY_MODEL = os.getenv("SECURITY_MODEL", "claude-sonnet-4-20250514")

    # New Travel & Finance Agents
    HOLIDAY_PLANNER_MODEL = os.getenv("HOLIDAY_PLANNER_MODEL", "gpt-4o")
    REGION_ANALYZER_MODEL = os.getenv("REGION_ANALYZER_MODEL", "gpt-4o")
    ASYMMETRIC_REVIEWER_MODEL = os.getenv("ASYMMETRIC_REVIEWER_MODEL", "gpt-4o")
    CURRENT_EVENTS_MODEL = os.getenv("CURRENT_EVENTS_MODEL", "gpt-4o")
    WEATHER_MODEL = os.getenv("WEATHER_MODEL", "gpt-4o-mini")
    ACCOUNTANT_MODEL = os.getenv("ACCOUNTANT_MODEL", "gpt-4o")
    PRICE_ANALYST_MODEL = os.getenv("PRICE_ANALYST_MODEL", "gemini-2.0-pro")
    MARKET_SHARK_MODEL = os.getenv("MARKET_SHARK_MODEL", "gemini-2.0-pro")
    CRYPTO_ORACLE_MODEL = os.getenv("CRYPTO_ORACLE_MODEL", "gemini-2.0-pro")

    OUTPUT_DIR = os.getenv("OUTPUT_DIR", "./generated-app")
    MAX_RETRIES = int(os.getenv("MAX_RETRIES", "2"))
    MAX_CONCURRENT_LLM_CALLS = int(os.getenv("MAX_CONCURRENT_LLM_CALLS", "5"))
    AGENT_CONFIG_PATH = os.getenv("AGENT_CONFIG_PATH", "")
    CHECKPOINT_DIR = os.getenv("CHECKPOINT_DIR", "./.claw-checkpoints")
