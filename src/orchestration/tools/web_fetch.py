# Shim: re-exports pydantic_agents.core.tools.web_fetch so `orchestration.tools.web_fetch`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
from pydantic_agents.core.tools.web_fetch import *  # noqa: F401,F403
