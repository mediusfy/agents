# Shim: re-exports pydantic_agents.agents.test_eng so `orchestration.agents.test_eng`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
from pydantic_agents.agents.test_eng import *  # noqa: F401,F403
