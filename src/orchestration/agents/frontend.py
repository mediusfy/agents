# Shim: re-exports pydantic_agents.agents.frontend so `orchestration.agents.frontend`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
from pydantic_agents.agents.frontend import *  # noqa: F401,F403
