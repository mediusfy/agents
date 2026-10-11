# Shim: re-exports pydantic_agents.core.session_recorder so `orchestration.session_recorder`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
from pydantic_agents.core.session_recorder import *  # noqa: F401,F403
