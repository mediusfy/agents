import asyncio
import uuid
import logging
from typing import Dict, Tuple, List, Optional

from pydantic_ai import Agent
from openclaw.memory import long_term_memory

logger = logging.getLogger(__name__)

class AgentBus:
    def __init__(self):
        self.registry: Dict[str, Tuple[Agent, List[str], Optional[callable]]] = {}
        self._active_queries: Dict[str, set] = {}

    def register(self, agent_name: str, agent: Agent, capabilities: List[str], deps_factory: Optional[callable] = None):
        self.registry[agent_name] = (agent, capabilities, deps_factory)

    async def query(self, capability: str, prompt: str, timeout: int = 30, caller_id: str = "root") -> str:
        query_id = f"{caller_id}->{capability}"
        logger.info(f"A2A Query [{query_id}]: Capability '{capability}' requested.")

        relevant_memories = await long_term_memory.get_relevant_memories(prompt)
        if relevant_memories:
            context = "Relevant information from past activities:\n"
            for mem in relevant_memories:
                context += f"- {mem.content}\n"
            prompt_with_context = f"{context}\n---\nOriginal Task:\n{prompt}"
        else:
            prompt_with_context = prompt
            
        target_agent: Optional[Agent] = None
        target_deps_factory: Optional[callable] = None
        target_name = ""
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
            async def _run():
                deps = target_deps_factory() if target_deps_factory else None
                if deps is not None:
                    res = await target_agent.run(prompt_with_context, deps=deps)
                else:
                    res = await target_agent.run(prompt_with_context)
                return str(res.data)

            result = await asyncio.wait_for(_run(), timeout=timeout)
            await long_term_memory.add_memory(f"Task: {prompt}\nResponse: {result}")
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

agent_bus = AgentBus()
