import importlib
import pkgutil
from typing import Dict, Optional, Set, List, Callable, Tuple
from pydantic_ai import Agent

class AgentRegistry:
    def __init__(self):
        self._agents: Dict[str, Tuple[Agent, List[str], Optional[Callable]]] = {}
        self._initialized: Set[str] = set()

    def register(self, name: str, agent: Agent, capabilities: List[str], deps_factory: Optional[Callable] = None):
        if name in self._agents:
            raise ValueError(f"Agent '{name}' is already registered.")
        self._agents[name] = (agent, capabilities, deps_factory)

    def unregister(self, name: str):
        self._agents.pop(name, None)
        self._initialized.discard(name)

    def get(self, name: str) -> Agent:
        agent_tuple = self._agents.get(name)
        if agent_tuple is None:
            raise ValueError(f"Agent '{name}' is not registered.")
        
        agent = agent_tuple[0]
        if name not in self._initialized:
            self._lazy_init(name, agent)
            self._initialized.add(name)
        return agent

    def _lazy_init(self, name: str, agent: Agent):
        from openclaw.tool_assignments import get_tool_categories
        from openclaw.tools import apply_tools
        categories = get_tool_categories(name)
        if categories:
            apply_tools(agent, name, categories)

    def list_agents(self) -> list[str]:
        return list(self._agents.keys())

    def items(self):
        return self._agents.items()

    def autodiscover(self):
        import openclaw.agents
        package = openclaw.agents
        prefix = package.__name__ + "."
        for _importer, modname, _ispkg in pkgutil.iter_modules(package.__path__, prefix):
            importlib.import_module(modname)

registry = AgentRegistry()
