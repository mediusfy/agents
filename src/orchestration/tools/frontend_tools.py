# Shim: re-exports pydantic_agents.core.tools.frontend_tools so `orchestration.tools.frontend_tools`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
from pydantic_agents.core.tools.frontend_tools import *  # noqa: F401,F403
