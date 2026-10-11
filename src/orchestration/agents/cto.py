# Shim: re-exports pydantic_agents.agents.cto so `orchestration.agents.cto`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
from pydantic_agents.agents.cto import *  # noqa: F401,F403
