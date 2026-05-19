from pydantic import BaseModel, Field
from typing import List, Optional

class Task(BaseModel):
    """A single, executable task in a larger plan."""
    id: str = Field(description="A unique identifier for the task.")
    capability: str = Field(description="The specific capability required to perform the task.")
    prompt: str = Field(description="A detailed prompt for the agent performing the task.")
    dependencies: List[str] = Field(default_factory=list, description="A list of task IDs that must be completed before this task can start.")

class Plan(BaseModel):
    """A multi-step plan to achieve a high-level goal."""
    goal: str = Field(description="The high-level goal the plan is designed to achieve.")
    tasks: List[Task] = Field(description="A list of tasks that make up the plan.")
