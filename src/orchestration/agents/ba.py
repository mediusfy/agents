# Shim: re-exports pydantic_agents.agents.ba so `orchestration.agents.ba`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
from pydantic_agents.agents.ba import *  # noqa: F401,F403
