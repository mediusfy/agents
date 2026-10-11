# Shim: re-exports pydantic_agents.core.tools.test_tools so `orchestration.tools.test_tools`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
from pydantic_agents.core.tools.test_tools import *  # noqa: F401,F403
