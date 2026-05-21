import json

import redis
from pydantic import BaseModel, Field

from .memory import WorkingMemory


class Task(BaseModel):
    id: str
    capability: str
    prompt: str
    caller_id: str | None = "root"
    working_memory: WorkingMemory = Field(default_factory=WorkingMemory)


class TaskQueue:
    def __init__(self, host: str = "localhost", port: int = 6379, db: int = 0):
        self.redis = redis.Redis(host=host, port=port, db=db, decode_responses=True)
        self.queue_name = "openclaw_task_queue"
        self.pending_approval_queue_name = "openclaw_pending_approval_queue"

    def publish_task(self, task: Task):
        """Publishes a task to the Redis queue."""
        self.redis.lpush(self.queue_name, task.model_dump_json())

    def publish_for_approval(self, task: Task):
        """Publishes a task to the pending approval queue."""
        self.redis.lpush(self.pending_approval_queue_name, task.model_dump_json())

    def consume_task(self) -> Task | None:
        """Consumes a task from the Redis queue (blocking)."""
        _, task_json = self.redis.brpop(self.queue_name)
        if task_json:
            return Task(**json.loads(task_json))
        return None


task_queue = TaskQueue()
