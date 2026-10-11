# ruff: noqa: F401  (re-export shim; unused-looking imports are the point)
# Shim: re-exports pydantic_agents.core.models.factory so `orchestration.models.factory`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
#
# Explicit named imports (not `import *`) so mypy can resolve
# `from orchestration.X import name` at downstream call sites.
from pydantic_agents.core.models.factory import (
    PROVIDER_BASE_URLS,
    PROVIDER_KEY_VARS,
    create_model,
    logger,
    settings,
)
