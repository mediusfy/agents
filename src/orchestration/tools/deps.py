# ruff: noqa: F401  (re-export shim; unused-looking imports are the point)
# Shim: re-exports pydantic_agents.core.tools.deps so `orchestration.tools.deps`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
#
# Explicit named imports (not `import *`) so mypy can resolve
# `from orchestration.X import name` at downstream call sites.
from pydantic_agents.core.tools.deps import (
    RunContext,
    check_go_package,
    check_npm_package,
    check_package_version,
    check_pypi_package,
    register_tool,
)
