# ruff: noqa: F401  (re-export shim; unused-looking imports are the point)
# Shim: re-exports pydantic_agents.agents.service_engineer so `orchestration.agents.service_engineer`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
#
# Explicit named imports (not `import *`) so mypy can resolve
# `from orchestration.X import name` at downstream call sites.
from pydantic_agents.agents.service_engineer import (
    Agent,
    Artifact,
    Path,
    PathTraversalError,
    RunContext,
    _resolve_sandboxed,
    create_model,
    list_directory,
    read_file,
    run_gofmt_check,
    service_engineer_agent,
    settings,
)
