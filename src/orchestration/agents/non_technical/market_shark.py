# ruff: noqa: F401  (re-export shim; unused-looking imports are the point)
# Shim: re-exports pydantic_agents.agents.non_technical.market_shark so `orchestration.agents.non_technical.market_shark`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
#
# Explicit named imports (not `import *`) so mypy can resolve
# `from orchestration.X import name` at downstream call sites.
from pydantic_agents.agents.non_technical.market_shark import (
    Agent,
    MarketSharkDeps,
    create_model,
    dataclass,
    market_shark_agent,
    settings,
    shark_prompt,
)
