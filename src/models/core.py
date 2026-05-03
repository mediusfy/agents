from typing import List, Optional, Dict, Any
from pydantic import BaseModel, Field
from enum import Enum

class EventTrigger(BaseModel):
    id: str
    name: str = Field(description="Name of the event, e.g., OrderCreated")
    description: str

class UserStory(BaseModel):
    id: str
    title: str
    gherkin: str = Field(description="Given/When/Then acceptance criteria")
    event_triggers: List[EventTrigger] = Field(default_factory=list)

class Artifact(BaseModel):
    agent_name: str
    files: Dict[str, str] = Field(
        description="Map of file paths to their contents"
    )
    metadata: Dict[str, Any] = Field(
        default_factory=lambda: {
            "user_story_id": "",
            "service_name": "",
            "language": "",
            "framework": "",
        }
    )

class RiskLevel(str, Enum):
    LOW = "LOW"
    MEDIUM = "MEDIUM"
    HIGH = "HIGH"
    CRITICAL = "CRITICAL"

class ReviewResult(BaseModel):
    approved: bool
    feedback: List[str]
    security_score: int = Field(ge=0, le=100)
    risk_level: RiskLevel
