import asyncio
import uuid
import logging
from typing import Dict, Tuple, List, Optional
from pydantic_ai import Agent

logger = logging.getLogger(__name__)

class AgentBus:
    def __init__(self):
        # Maps agent_name -> (Agent, List[capability])
        self.registry: Dict[str, Tuple[Agent, List[str]]] = {}
        # Simple cycle detection per conversation_id
        self._active_queries: Dict[str, set] = {}

    def register(self, agent_name: str, agent: Agent, capabilities: List[str]):
        self.registry[agent_name] = (agent, capabilities)

    async def query(self, capability: str, prompt: str, timeout: int = 30) -> str:
        conversation_id = str(uuid.uuid4())
        logger.info(f"A2A Query [{conversation_id}]: Capability '{capability}' requested.")
        
        # Find capable agent
        target_agent: Optional[Agent] = None
        target_name: Optional[str] = None
        for name, (agent, caps) in self.registry.items():
            if capability in caps:
                target_agent = agent
                target_name = name
                break
                
        if not target_agent:
            msg = f"No agent found with capability '{capability}'"
            logger.warning(msg)
            return f"Error: {msg}"
            
        if capability in self._active_queries.get(conversation_id, set()):
            msg = f"Cyclic A2A call detected for capability '{capability}'"
            logger.error(msg)
            return f"Error: {msg}"
            
        self._active_queries.setdefault(conversation_id, set()).add(capability)
        
        try:
            # Wrap the call with timeout
            async def _run():
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
            self._active_queries[conversation_id].remove(capability)
            if not self._active_queries[conversation_id]:
                del self._active_queries[conversation_id]

# Global bus instance to be used across the application
agent_bus = AgentBus()
