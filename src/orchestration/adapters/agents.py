import asyncio
import random
from abc import ABC, abstractmethod
from typing import Any

from pydantic_ai import UnexpectedModelBehavior, UsageLimits
from tenacity import retry, retry_if_exception_type, stop_after_attempt, wait_exponential

from orchestration.prompt_manager import prompt_manager
from orchestration.telemetry import telemetry


class AgentProviderPort(ABC):
    """Abstracts the interaction with the underlying LLM framework."""

    @abstractmethod
    async def run_agent(
        self,
        semaphore: asyncio.Semaphore,
        agent_name: str,
        agent: Any,
        prompt: str,
        deps: Any = None,
        timeout: float = 3600.0,
    ) -> Any:
        pass


def _jittered_wait(retry_state):
    """Exponential backoff with jitter (full-jitter strategy)."""
    attempt = retry_state.attempt_number
    delay = min(60, 2 * 2 ** (attempt - 1))
    return delay * random.uniform(0.5, 1.5)


class PydanticAIAgentProvider(AgentProviderPort):
    """Concrete implementation using pydantic_ai for agent execution."""

    async def run_agent(
        self,
        semaphore: asyncio.Semaphore,
        agent_name: str,
        agent: Any,
        prompt: str,
        deps: Any = None,
        timeout: float = 600.0,
    ) -> Any:
        system_prompt = prompt_manager.get_prompt(agent_name)
        if system_prompt:
            agent._system_prompt = system_prompt

        async with semaphore:

            @retry(
                stop=stop_after_attempt(3),
                wait=_jittered_wait,
                retry=retry_if_exception_type(
                    (TimeoutError, ConnectionError, OSError, UnexpectedModelBehavior)
                ),
                reraise=True,
            )
            async def _run_with_retry():
                coro = (
                    agent.run(prompt, deps=deps, usage_limits=UsageLimits(request_limit=500))
                    if deps is not None
                    else agent.run(prompt, usage_limits=UsageLimits(request_limit=500))
                )
                return await asyncio.wait_for(coro, timeout=timeout)

            return await telemetry.track(agent_name, _run_with_retry)
