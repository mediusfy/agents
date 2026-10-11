# ruff: noqa: F401  (re-export shim; unused-looking imports are the point)
# Shim: re-exports pydantic_agents.agents.non_technical.region_analyzer so `orchestration.agents.non_technical.region_analyzer`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
#
# Explicit named imports (not `import *`) so mypy can resolve
# `from orchestration.X import name` at downstream call sites.
from pydantic_agents.agents.non_technical.region_analyzer import (
    Agent,
    RegionAnalyzerDeps,
    analyzer_prompt,
    create_model,
    dataclass,
    region_analyzer_agent,
    settings,
)
