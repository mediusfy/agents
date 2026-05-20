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
