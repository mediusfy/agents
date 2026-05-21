"""Agent-to-Agent (A2A) communication bus.

This module provides backward-compatible wrappers around the unified AgentRegistry.
Direct use of AgentBus is deprecated; prefer `registry` from openclaw.registry.
"""

import logging
from collections.abc import Callable

from openclaw.registry import registry

logger = logging.getLogger(__name__)


class AgentBus:
    """Backward-compatible wrapper around AgentRegistry.

    Deprecated: Use `registry` from openclaw.registry directly.
    """

    def __init__(self):
        self.registry = registry

    def register(self, agent_name: str, agent, capabilities: list[str], deps_factory: Callable | None = None):
        """Delegate to the unified registry."""
        self.registry.register(agent_name, agent, capabilities, deps_factory)

    async def query(self, capability: str, prompt: str, timeout: float | None = None, deps: dict | None = None) -> str:
        """Query an agent by capability via the unified registry."""
        return await self.registry.query(capability, prompt, timeout, deps)

    def dispatch_task(self, capability: str, prompt: str, caller_id: str = "root") -> str:
        """Dispatch a task via the unified registry."""
        return self.registry.dispatch_task(capability, prompt, caller_id)


agent_bus = AgentBus()
