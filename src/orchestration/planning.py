# Shim: re-exports pydantic_agents.core.planning so `orchestration.planning`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
from pydantic_agents.core.planning import *  # noqa: F401,F403
