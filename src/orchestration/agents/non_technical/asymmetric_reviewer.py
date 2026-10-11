# ruff: noqa: F401  (re-export shim; unused-looking imports are the point)
# Shim: re-exports pydantic_agents.agents.non_technical.asymmetric_reviewer so `orchestration.agents.non_technical.asymmetric_reviewer`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
#
# Explicit named imports (not `import *`) so mypy can resolve
# `from orchestration.X import name` at downstream call sites.
from pydantic_agents.agents.non_technical.asymmetric_reviewer import (
    Agent,
    AsymmetricReviewerDeps,
    asymmetric_reviewer_agent,
    create_model,
    dataclass,
    reviewer_prompt,
    settings,
)
