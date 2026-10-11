# Shim: re-exports pydantic_agents.agents.non_technical.crypto_oracle so `orchestration.agents.non_technical.crypto_oracle`
# keeps working for existing callers while the real implementation lives in the
# externally-installed pydantic-agents package (single shared registry/settings).
from pydantic_agents.agents.non_technical.crypto_oracle import *  # noqa: F401,F403
