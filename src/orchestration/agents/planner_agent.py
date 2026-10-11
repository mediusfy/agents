# ruff: noqa: F401  (re-export shim; unused-looking imports are the point)
# Shim: re-exports pydantic_agents.agents.planner_agent so `orchestration.agents.planner_agent`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
#
# Explicit named imports (not `import *`) so mypy can resolve
# `from orchestration.X import name` at downstream call sites.
from pydantic_agents.agents.planner_agent import (
    Agent,
    Plan,
    create_model,
    planner_agent,
    settings,
    system_prompt,
)
