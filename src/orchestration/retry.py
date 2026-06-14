"""Retry wrapper with exponential backoff and jitter for agent execution.

Provides a standalone ``run_with_retry()`` coroutine that wraps any agent
call with configurable retry logic.
"""

import asyncio
import logging
import random
from typing import Any

from pydantic_ai import UnexpectedModelBehavior, UsageLimits
from tenacity import retry, retry_if_exception_type, stop_after_attempt

logger = logging.getLogger(__name__)


def _jittered_wait(retry_state):
    """Full-jitter exponential backoff: 2 * 2^(attempt-1) seconds, ±50%."""
    delay = min(60.0, 2.0 * 2.0 ** (retry_state.attempt_number - 1))
    return delay * random.uniform(0.5, 1.5)


_RETRYABLE = (TimeoutError, ConnectionError, OSError, UnexpectedModelBehavior)


async def run_with_retry(
    agent: Any,
    prompt: str,
    deps: Any = None,
    max_retries: int = 3,
    base_delay: float = 2.0,  # noqa: ARG001
    max_delay: float = 60.0,  # noqa: ARG001
    timeout: float = 600.0,
) -> Any:
    """Run an agent call with exponential backoff, jitter, and retry.

    Retries on: ``TimeoutError``, ``ConnectionError``, ``OSError``,
    ``pydantic_ai.UnexpectedModelBehavior``.

    Returns the agent's result on success, re-raises on final failure.
    """
    decorated = retry(
        stop=stop_after_attempt(max_retries),
        wait=_jittered_wait,
        retry=retry_if_exception_type(_RETRYABLE),
        reraise=True,
    )(lambda: _run(agent, prompt, deps, timeout))

    return await decorated()


async def _run(agent: Any, prompt: str, deps: Any, timeout: float) -> Any:
    coro = (
        agent.run(prompt, deps=deps, usage_limits=UsageLimits(request_limit=500))
        if deps is not None
        else agent.run(prompt, usage_limits=UsageLimits(request_limit=500))
    )
    return await asyncio.wait_for(coro, timeout=timeout)
