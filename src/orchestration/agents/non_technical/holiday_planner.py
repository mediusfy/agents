# ruff: noqa: F401  (re-export shim; unused-looking imports are the point)
# Shim: re-exports pydantic_agents.agents.non_technical.holiday_planner so `orchestration.agents.non_technical.holiday_planner`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
#
# Explicit named imports (not `import *`) so mypy can resolve
# `from orchestration.X import name` at downstream call sites.
from pydantic_agents.agents.non_technical.holiday_planner import (
    Agent,
    HolidayPlannerDeps,
    create_model,
    dataclass,
    holiday_planner_agent,
    planner_prompt,
    settings,
)
