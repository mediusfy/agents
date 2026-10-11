# Shim: re-exports pydantic_agents.core.tools.fs_tools so `orchestration.tools.fs_tools`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
from pydantic_agents.core.tools.fs_tools import *  # noqa: F401,F403
