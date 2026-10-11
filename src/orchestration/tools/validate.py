# ruff: noqa: F401  (re-export shim; unused-looking imports are the point)
# Shim: re-exports pydantic_agents.core.tools.validate so `orchestration.tools.validate`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
#
# Explicit named imports (not `import *`) so mypy can resolve
# `from orchestration.X import name` at downstream call sites.
from pydantic_agents.core.tools.validate import (
    RunContext,
    parse_go_ast,
    register_tool,
    validate_go_mod,
    validate_json,
    validate_protobuf,
    validate_yaml,
)
