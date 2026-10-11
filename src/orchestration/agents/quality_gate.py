# Shim: re-exports pydantic_agents.agents.quality_gate so `orchestration.agents.quality_gate`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
from pydantic_agents.agents.quality_gate import *  # noqa: F401,F403
