import asyncio
import uuid
import logging
from typing import Dict, Tuple, List, Optional

from pydantic_ai import Agent

logger = logging.getLogger(__name__)

class AgentBus:
    def __init__(self):
        # Maps agent_name -> (Agent, List[capability], Callable)
        self.registry: Dict[str, Tuple[Agent, List[str], Optional[callable]]] = {}
        # Simple cycle detection per conversation_id
        self._active_queries: Dict[str, set] = {}

    def register(self, agent_name: str, agent: Agent, capabilities: List[str], deps_factory: Optional[callable] = None):
        self.registry[agent_name] = (agent, capabilities, deps_factory)

    async def query(self, capability: str, prompt: str, timeout: int = 30, caller_id: str = "root") -> str:
        query_id = f"{caller_id}->{capability}"
        logger.info(f"A2A Query [{query_id}]: Capability '{capability}' requested.")
        
        # Find capable agent
        target_agent: Optional[Agent] = None
        target_deps_factory: Optional[callable] = None
        for name, (agent, caps, deps_fac) in self.registry.items():
            if capability in caps:
                target_agent = agent
                target_name = name
                target_deps_factory = deps_fac
                break
                
        if not target_agent:
            msg = f"No agent found with capability '{capability}'"
            logger.warning(msg)
            return f"Error: {msg}"
            
        if capability in self._active_queries.get(caller_id, set()):
            msg = f"Cyclic A2A call detected for capability '{capability}' (already active for caller '{caller_id}')"
            logger.error(msg)
            return f"Error: {msg}"
            
        self._active_queries.setdefault(caller_id, set()).add(capability)
        
        try:
            # Wrap the call with timeout
            async def _run():
                deps = target_deps_factory() if target_deps_factory else None
                if deps is not None:
                    res = await target_agent.run(prompt, deps=deps)
                else:
                    res = await target_agent.run(prompt)
                return str(res.data)

            result = await asyncio.wait_for(_run(), timeout=timeout)
            return result
        except asyncio.TimeoutError:
            msg = f"A2A query to '{target_name}' timed out after {timeout}s"
            logger.error(msg)
            return f"Error: {msg}"
        except Exception as e:
            msg = f"A2A query to '{target_name}' failed: {e}"
            logger.error(msg)
            return f"Error: {msg}"
        finally:
            active = self._active_queries.get(caller_id)
            if active:
                active.discard(capability)
                if not active:
                    del self._active_queries[caller_id]

# Global bus instance to be used across the application
agent_bus = AgentBus()
