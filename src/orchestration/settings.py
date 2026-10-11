# Shim: re-exports pydantic_agents.core.settings so `orchestration.settings`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
from pydantic_agents.core.settings import *  # noqa: F401,F403
