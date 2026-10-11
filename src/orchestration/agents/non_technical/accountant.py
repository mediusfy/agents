# ruff: noqa: F401  (re-export shim; unused-looking imports are the point)
# Shim: re-exports pydantic_agents.agents.non_technical.accountant so `orchestration.agents.non_technical.accountant`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
#
# Explicit named imports (not `import *`) so mypy can resolve
# `from orchestration.X import name` at downstream call sites.
from pydantic_agents.agents.non_technical.accountant import (
    AccountantDeps,
    Agent,
    accountant_agent,
    accountant_prompt,
    create_model,
    dataclass,
    settings,
)
