# Shim: re-exports pydantic_agents.core.models.core so `orchestration.models.core`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
from pydantic_agents.core.models.core import *  # noqa: F401,F403
