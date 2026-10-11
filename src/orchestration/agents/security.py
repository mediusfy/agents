# ruff: noqa: F401  (re-export shim; unused-looking imports are the point)
# Shim: re-exports pydantic_agents.agents.security so `orchestration.agents.security`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
#
# Explicit named imports (not `import *`) so mypy can resolve
# `from orchestration.X import name` at downstream call sites.
from pydantic_agents.agents.security import (
    Agent,
    SecurityDeps,
    SecurityReport,
    create_model,
    dataclass,
    security_agent,
    security_prompt,
    settings,
)
