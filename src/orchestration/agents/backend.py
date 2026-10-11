# ruff: noqa: F401  (re-export shim; unused-looking imports are the point)
# Shim: re-exports pydantic_agents.agents.backend so `orchestration.agents.backend`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
#
# Explicit named imports (not `import *`) so mypy can resolve
# `from orchestration.X import name` at downstream call sites.
from pydantic_agents.agents.backend import (
    Agent,
    Artifact,
    ProjectState,
    RunContext,
    backend_agent,
    backend_prompt,
    create_model,
    dataclass,
    generate_dockerfile,
    scaffold_go_service,
    settings,
)
