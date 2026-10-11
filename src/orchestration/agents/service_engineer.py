# Shim: re-exports pydantic_agents.agents.service_engineer so `orchestration.agents.service_engineer`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
from pydantic_agents.agents.service_engineer import *  # noqa: F401,F403
from pydantic_agents.agents.service_engineer import _resolve_sandboxed  # noqa: F401
