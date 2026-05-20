import uuid
import logging
from typing import Dict, Tuple, List, Optional
from pydantic_ai import Agent
from openclaw.task_queue import Task, task_queue

logger = logging.getLogger(__name__)

class AgentBus:
    def __init__(self):
        #TODO TECHNICAL DEBT
        #TODO used by workers to load the agent code but will deprecated and replaced by service discovery
        self.registry: Dict[str, Tuple[Agent, List[str], Optional[callable]]] = {}

    def register(self, agent_name: str, agent: Agent, capabilities: List[str], deps_factory: Optional[callable] = None):
        self.registry[agent_name] = (agent, capabilities, deps_factory)

    async def query(self, capability: str, prompt: str, timeout: Optional[float] = None, deps: Optional[dict] = None) -> str:
        """Directly query an agent by capability (backward-compatible synchronous-style API)."""
        import asyncio
        for agent_name, (agent, caps, deps_factory) in self.registry.items():
            if capability in caps:
                try:
                    resolved_deps = deps or {}
                    if deps_factory and not deps:
                        resolved_deps = deps_factory() if callable(deps_factory) else {}
                    if timeout:
                        result = await asyncio.wait_for(agent.run(prompt, deps=resolved_deps), timeout=timeout)
                    else:
                        result = await agent.run(prompt, deps=resolved_deps)
                    return str(result.data) if hasattr(result, 'data') else str(result)
                except asyncio.TimeoutError:
                    return f"Agent '{agent_name}' timed out for capability '{capability}'"
                except Exception as e:
                    logger.warning(f"Agent '{agent_name}' failed for capability '{capability}': {e}")
                    return f"Agent error: {e}"
        return f"No agent found for capability '{capability}'"

    def dispatch_task(self, capability: str, prompt: str, caller_id: str = "root") -> str:
        """
        Creates a task and publishes it to the message queue.
        Returns the task ID for tracking.
        """
        task_id = str(uuid.uuid4())
        task = Task(
            id=task_id,
            capability=capability,
            prompt=prompt,
            caller_id=caller_id,
        )
        task_queue.publish_task(task)
        logger.info(f"Dispatched task {task_id} for capability '{capability}'.")
        return task_id

agent_bus = AgentBus()
