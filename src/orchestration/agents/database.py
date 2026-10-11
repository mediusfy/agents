# ruff: noqa: F401  (re-export shim; unused-looking imports are the point)
# Shim: re-exports pydantic_agents.agents.database so `orchestration.agents.database`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
#
# Explicit named imports (not `import *`) so mypy can resolve
# `from orchestration.X import name` at downstream call sites.
from pydantic_agents.agents.database import (
    Agent,
    Artifact,
    DatabaseDeps,
    RunContext,
    create_model,
    database_agent,
    dataclass,
    generate_migration_template,
    generate_seed_script,
    scaffold_redis_config,
    settings,
)
