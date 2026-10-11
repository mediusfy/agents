# ruff: noqa: F401  (re-export shim; unused-looking imports are the point)
# Shim: re-exports pydantic_agents.agents.quality_gate so `orchestration.agents.quality_gate`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
#
# Explicit named imports (not `import *`) so mypy can resolve
# `from orchestration.X import name` at downstream call sites.
from pydantic_agents.agents.quality_gate import (
    Agent,
    QualityGateResult,
    create_model,
    quality_gate_agent,
    quality_gate_prompt,
    settings,
)
