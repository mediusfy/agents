# ruff: noqa: F401  (re-export shim; unused-looking imports are the point)
# Shim: re-exports pydantic_agents.core.vector_db so `orchestration.vector_db`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
#
# Explicit named imports (not `import *`) so mypy can resolve
# `from orchestration.X import name` at downstream call sites.
from pydantic_agents.core.vector_db import (
    Any,
    OrgitrationDependencyError,
    VectorDBManager,
    _get_pool,
    _set_test_pool,
    _to_embedding,
    logger,
    settings,
    vector_db,
)
