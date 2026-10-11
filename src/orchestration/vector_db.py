# Shim: re-exports pydantic_agents.core.vector_db so `orchestration.vector_db`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
from pydantic_agents.core.vector_db import *  # noqa: F401,F403
from pydantic_agents.core.vector_db import _get_pool, _set_test_pool, _to_embedding  # noqa: F401
