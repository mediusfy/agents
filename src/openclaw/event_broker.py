"""Event Broker — asynchronous handoffs for heavy workloads.

ASYNC HANDOFFS FOR HEAVY WORKLOADS:
Instead of synchronous MCP calls that may timeout on long-running operations
(builds, test suites, deployments), the event broker provides an event-driven
model. The Orchestrator fires an event → worker agents pick it up → publish
a "Task Complete" event back.

This module provides:
  - Event types (TaskSubmitted, TaskComplete, TaskFailed)
  - In-memory event broker with task tracking
  - Polling interface (check_task_status)
  - Awaitable interface (wait_for)

For production, this could be backed by Redis pub/sub, NATS, or similar.
"""

import asyncio
import enum
import logging
import time
import uuid
from dataclasses import dataclass, field
from typing import Any

import logfire

logger = logging.getLogger(__name__)


class EventKind(enum.Enum):
    TASK_SUBMITTED = "task_submitted"
    TASK_STARTED = "task_started"
    TASK_COMPLETED = "task_completed"
    TASK_FAILED = "task_failed"
    TASK_TIMEOUT = "task_timeout"


@dataclass
class Event:
    kind: EventKind
    data: dict[str, Any]
    id: str = field(default_factory=lambda: f"evt_{uuid.uuid4().hex[:12]}")
    timestamp: float = field(default_factory=time.time)


@dataclass
class TaskRecord:
    id: str
    status: str = "pending"  # pending, running, completed, failed, timeout
    result: str | None = None
    created_at: float = field(default_factory=time.time)
    completed_at: float | None = None
    _completion_event: asyncio.Event = field(default_factory=asyncio.Event)


class EventBroker:
    """In-memory event broker for async task handoffs.

    Handles task submission, status tracking, and completion notification.
    Worker agents check for pending tasks and publish completion events.
    """

    def __init__(self) -> None:
        self._tasks: dict[str, TaskRecord] = {}
        self._events: list[Event] = []

    def submit(self, event: Event) -> str:
        """Submit a task event and return a task ID for polling."""
        task_id = f"task_{uuid.uuid4().hex[:12]}"
        record = TaskRecord(id=task_id)
        self._tasks[task_id] = record
        self._events.append(event)

        with logfire.span("event_broker.submit", task_id=task_id, kind=event.kind.value, _level="info"):
            logger.info("Task %s submitted (%s)", task_id, event.kind.value)

        return task_id

    def complete(self, task_id: str, result: str) -> None:
        """Mark a task as completed with a result.

        Also stores the task result in the vector DB so future context
        retrieval can find it (vector-indexed task history).
        """
        record = self._tasks.get(task_id)
        if not record:
            logger.warning("Cannot complete unknown task: %s", task_id)
            return

        record.status = "completed"
        record.result = result
        record.completed_at = time.time()
        record._completion_event.set()

        self._events.append(Event(kind=EventKind.TASK_COMPLETED, data={"task_id": task_id, "result": result}))

        # Store in vector DB for future context retrieval
        try:
            from openclaw.vector_db import vector_db

            store_result = result if isinstance(result, str) else str(result)
            vector_db.add_documents(
                "project",
                [f"Task {task_id} completed: {store_result}"],
                [{"task_id": task_id, "status": "completed", "source": "event_broker"}],
                [f"task:{task_id}"],
            )
        except Exception as e:
            logger.debug("Could not store task result in vector DB: %s", e)

        with logfire.span("event_broker.complete", task_id=task_id, _level="info"):
            logger.info("Task %s completed (stored in vector DB)", task_id)

    def fail(self, task_id: str, error: str) -> None:
        """Mark a task as failed with an error message."""
        record = self._tasks.get(task_id)
        if not record:
            logger.warning("Cannot fail unknown task: %s", task_id)
            return

        record.status = "failed"
        record.result = error
        record.completed_at = time.time()
        record._completion_event.set()

        self._events.append(Event(kind=EventKind.TASK_FAILED, data={"task_id": task_id, "error": error}))

        with logfire.span("event_broker.fail", task_id=task_id, _level="warn"):
            logger.warning("Task %s failed: %s", task_id, error)

    def get_status(self, task_id: str) -> dict[str, Any] | None:
        """Get the current status of a task."""
        record = self._tasks.get(task_id)
        if not record:
            return None

        return {
            "status": record.status,
            "result": record.result if record.status in ("completed", "failed") else "pending",
            "created_at": record.created_at,
            "completed_at": record.completed_at,
            "elapsed_seconds": round(time.time() - record.created_at, 1),
        }

    async def wait_for(self, task_id: str, timeout_seconds: int = 300) -> dict[str, Any] | None:
        """Wait asynchronously for a task to complete.

        Args:
            task_id: The task to wait for.
            timeout_seconds: Max time to wait (default 5 min).

        Returns:
            Status dict, or None if timeout.
        """
        record = self._tasks.get(task_id)
        if not record:
            return None

        if record.status in ("completed", "failed"):
            return self.get_status(task_id)

        try:
            await asyncio.wait_for(record._completion_event.wait(), timeout=timeout_seconds)
            return self.get_status(task_id)
        except TimeoutError:
            record.status = "timeout"
            with logfire.span("event_broker.timeout", task_id=task_id, timeout=timeout_seconds, _level="warn"):
                logger.warning("Task %s timed out after %ds", task_id, timeout_seconds)
            return {
                "status": "timeout",
                "result": f"Timed out after {timeout_seconds}s",
                "created_at": record.created_at,
                "completed_at": None,
                "elapsed_seconds": timeout_seconds,
            }

    def get_pending_tasks(self) -> list[dict[str, Any]]:
        """Get all pending tasks — for worker agents to discover work."""
        return [
            {"id": tid, "status": rec.status, "created_at": rec.created_at}
            for tid, rec in self._tasks.items()
            if rec.status == "pending"
        ]

    def get_events(self, since_id: str | None = None) -> list[Event]:
        """Get all events since a given event ID."""
        if since_id is None:
            return list(self._events)
        found = False
        result: list[Event] = []
        for evt in self._events:
            if found:
                result.append(evt)
            elif evt.id == since_id:
                found = True
        return result


# Singleton
event_broker = EventBroker()
