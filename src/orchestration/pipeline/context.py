# Shim: re-exports pydantic_agents.core.pipeline.context so `orchestration.pipeline.context`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
from pydantic_agents.core.pipeline.context import *  # noqa: F401,F403
