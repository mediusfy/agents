import os

class AgentSettings:
    BA_MODEL = os.getenv("BA_MODEL", "gpt-4o-mini")
    BACKEND_MODEL = os.getenv("BACKEND_MODEL", "claude-sonnet-4-20250514")
    FRONTEND_MODEL = os.getenv("FRONTEND_MODEL", "gpt-4o")
    TEST_MODEL = os.getenv("TEST_MODEL", "gpt-4o-mini")
    SRE_MODEL = os.getenv("SRE_MODEL", "gemini-2.0-flash")
    REVIEW_MODEL = os.getenv("REVIEW_MODEL", "claude-sonnet-4-20250514")

    OUTPUT_DIR = os.getenv("OUTPUT_DIR", "./generated-app")
    MAX_RETRIES = int(os.getenv("MAX_RETRIES", "2"))
