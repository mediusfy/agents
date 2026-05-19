import redis
import json
from pydantic import BaseModel
from typing import Dict, Any, Optional

class Task(BaseModel):
    id: str
    capability: str
    prompt: str
    caller_id: Optional[str] = "root"
    context: Optional[Dict[str, Any]] = None

class TaskQueue:
    def __init__(self, host: str = 'localhost', port: int = 6379, db: int = 0):
        self.redis = redis.Redis(host=host, port=port, db=db, decode_responses=True)
        self.queue_name = "openclaw_task_queue"

    def publish_task(self, task: Task):
        """Publishes a task to the Redis queue."""
        self.redis.lpush(self.queue_name, task.model_dump_json())

    def consume_task(self) -> Optional[Task]:
        """Consumes a task from the Redis queue (blocking)."""
        _, task_json = self.redis.brpop(self.queue_name)
        if task_json:
            return Task(**json.loads(task_json))
        return None

task_queue = TaskQueue()
