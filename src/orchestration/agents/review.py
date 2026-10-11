# ruff: noqa: F401  (re-export shim; unused-looking imports are the point)
# Shim: re-exports pydantic_agents.agents.review so `orchestration.agents.review`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
#
# Explicit named imports (not `import *`) so mypy can resolve
# `from orchestration.X import name` at downstream call sites.
from pydantic_agents.agents.review import (
    REVIEW_BLUEPRINT_SUMMARY,
    REVIEW_BOUNDED_CONTEXTS,
    REVIEW_STRICT_MODE,
    Agent,
    ReviewResult,
    create_model,
    review_agent,
    settings,
)
