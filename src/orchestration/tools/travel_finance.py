# Shim: re-exports pydantic_agents.core.tools.travel_finance so `orchestration.tools.travel_finance`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
from pydantic_agents.core.tools.travel_finance import *  # noqa: F401,F403
