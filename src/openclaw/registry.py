import asyncio
import importlib
import logging
import pkgutil
from collections.abc import Callable

from pydantic_ai import Agent

logger = logging.getLogger(__name__)


class AgentRegistry:
    def __init__(self):
        self._agents: dict[str, tuple[Agent, list[str], Callable | None, Callable | None]] = {}
        self._cap_index: dict[str, str] = {}  # capability -> agent_name
        self._initialized: set[str] = set()

    def register(
        self,
        name: str,
        agent: Agent,
        capabilities: list[str],
        deps_factory: Callable | None = None,
        post_process_hook: Callable | None = None,
    ):
        if name in self._agents:
            raise ValueError(f"Agent '{name}' is already registered.")
        self._agents[name] = (agent, capabilities, deps_factory, post_process_hook)
        for cap in capabilities:
            self._cap_index[cap] = name

    def unregister(self, name: str):
        agent_tuple = self._agents.pop(name, None)
        if agent_tuple:
            for cap in agent_tuple[1]:
                self._cap_index.pop(cap, None)
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

    async def query(self, capability: str, prompt: str, timeout: float | None = None, deps: dict | None = None) -> str:
        """Query an agent by capability, returning its response as a string.

        Uses an O(1) capability index instead of linear scan.
        """
        agent_name = self._cap_index.get(capability)
        if agent_name is None:
            return f"No agent found for capability '{capability}'"

        agent, _caps, deps_factory, _post_hook = self._agents[agent_name]
        try:
            resolved_deps = deps or {}
            if deps_factory and not deps:
                resolved_deps = deps_factory() if callable(deps_factory) else {}
            if timeout:
                result = await asyncio.wait_for(agent.run(prompt, deps=resolved_deps), timeout=timeout)
            else:
                result = await agent.run(prompt, deps=resolved_deps)
            return str(result.data) if hasattr(result, "data") else str(result)
        except TimeoutError:
            return f"Agent '{agent_name}' timed out for capability '{capability}'"
        except Exception as e:
            logger.warning("Agent '%s' failed for capability '%s': %s", agent_name, capability, e)
            return f"Agent error: {e}"


registry = AgentRegistry()
