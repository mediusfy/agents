# Shim: re-exports pydantic_agents.core.exceptions so `orchestration.exceptions`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
from pydantic_agents.core.exceptions import *  # noqa: F401,F403
