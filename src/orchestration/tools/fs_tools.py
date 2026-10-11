# ruff: noqa: F401  (re-export shim; unused-looking imports are the point)
# Shim: re-exports pydantic_agents.core.tools.fs_tools so `orchestration.tools.fs_tools`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
#
# Explicit named imports (not `import *`) so mypy can resolve
# `from orchestration.X import name` at downstream call sites.
from pydantic_agents.core.tools.fs_tools import (
    categories,
    list_dir,
    read_file,
    register_tool,
    search_files,
    write_file,
)
