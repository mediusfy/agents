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

class QualityGateResult(BaseModel):
    passed: bool
    complexity_score: int = Field(ge=0, le=100, description="0 is simple, 100 is overly complex/over-engineered")
    feedback: List[str]

class AgentAdvice(BaseModel):
    bottlenecks_identified: List[str] = Field(default_factory=list, description="Potential issues or bottlenecks spotted")
    recommendations: List[str] = Field(default_factory=list, description="Actionable advice for downstream agents")
    approved_to_proceed: bool = Field(default=True)

class ActivityLog(BaseModel):
    pass_num: int
    agent_name: str
    action: str
    summary: str
    timestamp: str
    artifact_ids: List[str] = Field(default_factory=list)

class SecurityReport(BaseModel):
    passed: bool
    score: int
    feedback: List[str] = Field(default_factory=list)

class PipelineState(BaseModel):
    run_id: str
    stage: str
    attempt: int = 1
    user_stories: List[UserStory] = Field(default_factory=list)
    advisory_results: Dict[str, str] = Field(default_factory=dict)
    artifacts: List[Artifact] = Field(default_factory=list)
    feedback: Optional[str] = None

