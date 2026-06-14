from orchestration.adapters.agents import AgentProviderPort


class StageRunner:
    def __init__(self, agent_provider: AgentProviderPort | None = None):
        self.agent_provider = agent_provider

    @property
    def provider(self) -> AgentProviderPort:
        if self.agent_provider is None:
            raise RuntimeError("AgentProviderPort is not configured")
        return self.agent_provider
