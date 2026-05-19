"""Startup validation for the OpenClaw ecosystem.

Ensures required configuration is present and valid before the pipeline runs.
"""

import logging
import os
from pathlib import Path

from openclaw.settings import settings

logger = logging.getLogger(__name__)


PLACEHOLDER = [
    "sk-...",
    "sk-ant-...",
    "API_KEY",
    "api-key",
]


def _is_placeholder(value: str | None) -> bool:
    if not value:
        return False
    stripped = value.strip()
    return any(p in stripped for p in PLACEHOLDER)


def validate_api_keys() -> list[str]:
    """Check that at least one API key is configured and not a placeholder."""
    errors: list[str] = []
    keys = {
        "OPENAI_API_KEY": settings.openai_api_key,
        "ANTHROPIC_API_KEY": settings.anthropic_api_key,
        "GEMINI_API_KEY": settings.gemini_api_key,
    }
    configured = []
    for name, value in keys.items():
        if value and not _is_placeholder(value):
            configured.append(name)
        elif _is_placeholder(value):
            errors.append(f"{name} appears to be a placeholder value. Set a real key in .env")
    if not configured:
        errors.append("No API keys configured. Set at least one of: OPENAI_API_KEY, ANTHROPIC_API_KEY, GEMINI_API_KEY")
    return errors


def validate_directories() -> list[str]:
    """Ensure output/checkpoint/vector-db directories are writable (read-only check, no FS mutation)."""
    errors: list[str] = []
    for name, path in [
        ("OUTPUT_DIR", settings.output_dir),
        ("CHECKPOINT_DIR", settings.checkpoint_dir),
        ("VECTOR_DB_DIR", settings.vector_db_dir),
    ]:
        try:
            resolved = Path(path).resolve()
            if resolved.exists():
                if not os.access(str(resolved), os.W_OK):
                    errors.append(f"{name} ({resolved}) exists but is not writable")
            else:
                parent = resolved.parent
                if not parent.exists() or not os.access(str(parent), os.W_OK):
                    errors.append(f"{name} ({resolved}) parent directory does not exist or is not writable")
        except (OSError, PermissionError) as e:
            errors.append(f"{name}={path}: {e}")
    return errors


def run_startup_checks() -> list[str]:
    """Run all startup checks and return a list of error messages."""
    errors: list[str] = []
    errors.extend(validate_api_keys())
    errors.extend(validate_directories())
    return errors


def assert_startup_checks():
    """Run startup checks and log warnings for any issues found."""
    errors = run_startup_checks()
    for err in errors:
        logger.warning("Startup check failed: %s", err)
    if errors:
        logger.warning("%d startup issue(s) found. The pipeline may fail at runtime.", len(errors))
    return errors
