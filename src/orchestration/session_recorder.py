# ruff: noqa: F401  (re-export shim; unused-looking imports are the point)
# Shim: re-exports pydantic_agents.core.session_recorder so `orchestration.session_recorder`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
#
# Explicit named imports (not `import *`) so mypy can resolve
# `from orchestration.X import name` at downstream call sites.
from pydantic_agents.core.session_recorder import (
    AgentRunRecord,
    Any,
    AsyncIterator,
    ContextVar,
    SessionRecorder,
    ToolCallRecord,
    asdict,
    current_run_context,
    dataclass,
    extract_traces,
    field,
    logger,
    recorder,
    summarize_traces,
)
