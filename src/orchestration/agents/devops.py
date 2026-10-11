# ruff: noqa: F401  (re-export shim; unused-looking imports are the point)
# Shim: re-exports pydantic_agents.agents.devops so `orchestration.agents.devops`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
#
# Explicit named imports (not `import *`) so mypy can resolve
# `from orchestration.X import name` at downstream call sites.
from pydantic_agents.agents.devops import (
    Agent,
    Artifact,
    DevopsDeps,
    RunContext,
    create_model,
    dataclass,
    devops_agent,
    generate_docker_compose,
    generate_github_action,
    generate_makefile,
    settings,
)
