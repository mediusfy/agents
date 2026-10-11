# ruff: noqa: F401  (re-export shim; unused-looking imports are the point)
# Shim: re-exports pydantic_agents.agents.non_technical.crypto_oracle so `orchestration.agents.non_technical.crypto_oracle`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
#
# Explicit named imports (not `import *`) so mypy can resolve
# `from orchestration.X import name` at downstream call sites.
from pydantic_agents.agents.non_technical.crypto_oracle import (
    Agent,
    CryptoOracleDeps,
    create_model,
    crypto_oracle_agent,
    dataclass,
    oracle_prompt,
    settings,
)
