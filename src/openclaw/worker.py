import asyncio
import logging
import signal
from collections.abc import Callable, Coroutine
from types import FrameType
from typing import Any

import logfire
from pydantic_ai import Agent

from openclaw.config import worker_settings
from openclaw.critical_actions import CRITICAL_CAPABILITIES
from openclaw.exceptions import AgentExecutionError, AgentNotFoundError
from openclaw.memory import long_term_memory
from openclaw.registry import registry
from openclaw.task_queue import Task, task_queue

logfire.configure()
logfire.instrument_pydantic()
log = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO)

shutdown_event = asyncio.Event()


class Worker:
    """
    An asynchronous worker that consumes tasks, delegates them to registered agents,
    and handles the lifecycle of task execution, including retries and validation.
    """

    def __init__(self):
        registry.autodiscover()
        log.info(
            "Worker initialized",
            extra={"autodiscovered_agents": registry.list_agents()},
        )

    async def main_loop(self):
        """The primary loop to consume and process tasks."""
        while not shutdown_event.is_set():
            try:
                task = task_queue.consume_task()
                if not task:
                    await asyncio.sleep(0.1)  # prevent busy-waiting
                    continue  # No task, loop again

                asyncio.create_task(self.process_task(task))

            except Exception:
                log.exception("Unhandled exception in main worker loop")
                # Avoid rapid-fire loops on unexpected errors
                await asyncio.sleep(1)

    async def process_task(self, task: Task):
        """
        Orchestrates the processing of a single task.
        """
        with logfire.span("worker.process_task", task_id=task.id, capability=task.capability) as span:
            log.info(
                "Processing task",
                extra={"task_id": task.id, "capability": task.capability},
            )

            if self._is_pending_approval(task, span):
                return

            try:
                agent, post_process_hook = self._find_agent_for_task(task)

                prompt = await self._enrich_prompt_with_memory(task.prompt, span)

                result, usage = await self._run_and_validate_with_retries(agent, prompt, task, post_process_hook)

                await self._handle_success(task, result, usage, span)

            except AgentNotFoundError as e:
                span.set_attribute("error", str(e))
                log.error(
                    "Agent not found for task",
                    extra={"capability": task.capability, "task_id": task.id},
                )
            except Exception as e:
                span.set_attribute("error", str(e))
                log.exception("Unexpected error processing task", extra={"task_id": task.id})

    def _is_pending_approval(self, task: Task, span) -> bool:
        """Checks for and handles tasks requiring human approval."""
        if task.capability in CRITICAL_CAPABILITIES:
            log.warning(
                "Task requires approval",
                extra={"task_id": task.id, "capability": task.capability},
            )
            task_queue.publish_for_approval(task)
            span.set_attribute("status", "pending_approval")
            return True
        return False

    def _find_agent_for_task(self, task: Task) -> tuple[Agent, Callable | None]:
        """Finds a registered agent for a given task by capability match."""
        for _agent_name, (agent_instance, caps, _deps_fac, post_hook) in registry.items():
            if task.capability in caps:
                return agent_instance, post_hook
        raise AgentNotFoundError(f"No agent found for capability '{task.capability}'")

    async def _enrich_prompt_with_memory(self, prompt: str, span) -> str:
        """Retrieves relevant memories and prepends them to the prompt."""
        relevant_memories = await long_term_memory.get_relevant_memories(prompt)
        if not relevant_memories:
            return prompt

        context = "Relevant information from past activities:\n"
        context += "\n".join(f"- {mem.content}" for mem in relevant_memories)
        prompt_with_context = f"{context}\n---\nOriginal Task:\n{prompt}"

        span.set_attribute("context_size", len(prompt_with_context))
        return prompt_with_context

    async def _run_and_validate_with_retries(
        self,
        agent: Agent,
        prompt: str,
        task: Task,
        post_process_hook: Callable[[str], Coroutine[Any, Any, None]] | None,
    ) -> tuple[str, dict | None]:
        """
        Executes the agent and runs validation, retrying on failure.
        """
        last_error = None
        for attempt in range(worker_settings.max_correction_attempts):
            with logfire.span("worker.attempt_task", attempt=attempt + 1) as attempt_span:
                try:
                    res = await agent.run(prompt)
                    result_str = str(res)

                    if post_process_hook:
                        await post_process_hook(result_str)

                    return result_str, getattr(agent, "token_usage", None)

                except AgentExecutionError as e:
                    last_error = e
                    self._handle_failure(task, e, attempt, attempt_span)
                    if not e.is_retryable:
                        break
                    prompt = (
                        f"The previous attempt failed with this error: {e}. Please correct the issue and try again."
                    )

        raise AgentExecutionError(
            f"Task failed after {worker_settings.max_correction_attempts} attempts. Last error: {last_error}"
        )

    def _handle_failure(self, task: Task, e: Exception, attempt: int, span):
        """Logs and records details of a failed attempt."""
        log.warning(
            "Task attempt failed",
            extra={
                "task_id": task.id,
                "attempt": f"{attempt + 1}/{worker_settings.max_correction_attempts}",
                "error": str(e),
            },
        )
        span.set_attribute("error", str(e))

    async def _handle_success(
        self,
        task: Task,
        result: str,
        usage: dict | None,
        span,
    ):
        """Logs success and adds the interaction to long-term memory."""
        if usage:
            span.set_attribute("prompt_tokens", usage.get("prompt_tokens"))
            span.set_attribute("completion_tokens", usage.get("completion_tokens"))

        updated_wm = task.working_memory.model_dump_json()
        log_content = f"Task: {task.prompt}\nResponse: {result}\nWorking Memory: {updated_wm}"
        await long_term_memory.add_memory(log_content)

        log.info("Task completed successfully", extra={"task_id": task.id})


def handle_shutdown_signal(signum: int, _frame: FrameType | None):
    """Handles graceful shutdown of the worker."""
    log.info(f"Received signal {signum}, shutting down gracefully...")
    shutdown_event.set()


async def main():
    """Initializes and runs the worker."""
    worker = Worker()
    await worker.main_loop()


if __name__ == "__main__":
    signal.signal(signal.SIGINT, handle_shutdown_signal)
    signal.signal(signal.SIGTERM, handle_shutdown_signal)
    asyncio.run(main())
