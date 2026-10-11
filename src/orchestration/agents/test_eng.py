# ruff: noqa: F401  (re-export shim; unused-looking imports are the point)
# Shim: re-exports pydantic_agents.agents.test_eng so `orchestration.agents.test_eng`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
#
# Explicit named imports (not `import *`) so mypy can resolve
# `from orchestration.X import name` at downstream call sites.
from pydantic_agents.agents.test_eng import (
    Agent,
    Artifact,
    BaseModel,
    GoTestOutput,
    RunContext,
    TestOutput,
    UsageLimits,
    create_model,
    generate_go_table_driven_tests,
    generate_test_suite,
    go_test_gen,
    go_test_prompt,
    settings,
    test_eng_agent,
    test_gen,
    test_prompt,
)
