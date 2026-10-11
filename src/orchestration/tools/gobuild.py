# ruff: noqa: F401  (re-export shim; unused-looking imports are the point)
# Shim: re-exports pydantic_agents.core.tools.gobuild so `orchestration.tools.gobuild`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
#
# Explicit named imports (not `import *`) so mypy can resolve
# `from orchestration.X import name` at downstream call sites.
from pydantic_agents.core.tools.gobuild import (
    GO_BUILD_TIMEOUT,
    GO_MOD_INIT_TIMEOUT,
    GO_MOD_TIDY_TIMEOUT,
    GO_VET_TIMEOUT,
    register_tool,
    run_go_build,
    run_go_vet,
)
