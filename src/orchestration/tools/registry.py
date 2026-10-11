# Shim: re-exports pydantic_agents.core.tools.registry so `orchestration.tools.registry`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
from pydantic_agents.core.tools.registry import *  # noqa: F401,F403
