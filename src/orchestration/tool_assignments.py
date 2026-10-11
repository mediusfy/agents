# Shim: re-exports pydantic_agents.core.tool_assignments so `orchestration.tool_assignments`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
from pydantic_agents.core.tool_assignments import *  # noqa: F401,F403
