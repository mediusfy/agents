# Shim: re-exports pydantic_agents.core.tools.a2a_tools so `orchestration.tools.a2a_tools`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
from pydantic_agents.core.tools.a2a_tools import *  # noqa: F401,F403
