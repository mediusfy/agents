from dagster import Definitions
from .memory_consolidator import consolidate_memories_job, daily_memory_consolidation_schedule

defs = Definitions(
    jobs=[consolidate_memories_job],
    schedules=[daily_memory_consolidation_schedule],
)
