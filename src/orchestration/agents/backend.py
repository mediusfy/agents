# Shim: re-exports pydantic_agents.agents.backend so `orchestration.agents.backend`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
from pydantic_agents.agents.backend import *  # noqa: F401,F403
