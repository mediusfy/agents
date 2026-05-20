from pydantic_settings import BaseSettings


class WorkerSettings(BaseSettings):
    """Configuration for the OpenClaw worker process."""

    # Maximum number of times the agent can attempt to correct a failed task.
    max_correction_attempts: int = 3
    # Time in seconds to wait for a new task before checking for shutdown.
    task_consume_timeout: float = 1.0


settings = WorkerSettings()
