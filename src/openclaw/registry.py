import asyncio
import importlib
import logging
import pkgutil
import uuid
from collections.abc import Callable

from pydantic_ai import Agent

from openclaw.task_queue import Task, task_queue

logger = logging.getLogger(__name__)


class AgentRegistry:
    def __init__(self):
        self._agents: dict[str, tuple[Agent, list[str], Callable | None, Callable | None]] = {}
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

    async def query(self, capability: str, prompt: str, timeout: float | None = None, deps: dict | None = None) -> str:
        """Query an agent by capability, returning its response as a string."""
        for _agent_name, (agent, caps, deps_factory, _post_hook) in self._agents.items():
            if capability in caps:
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
                    return f"Agent '{_agent_name}' timed out for capability '{capability}'"
                except Exception as e:
                    logger.warning("Agent '%s' failed for capability '%s': %s", _agent_name, capability, e)
                    return f"Agent error: {e}"
        return f"No agent found for capability '{capability}'"

    def dispatch_task(self, capability: str, prompt: str, caller_id: str = "root") -> str:
        """Create a task and publish it to the queue. Returns the task ID."""
        task_id = str(uuid.uuid4())
        task = Task(id=task_id, capability=capability, prompt=prompt, caller_id=caller_id)
        task_queue.publish_task(task)
        logger.info("Dispatched task %s for capability '%s'.", task_id, capability)
        return task_id


registry = AgentRegistry()
