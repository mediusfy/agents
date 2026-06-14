"""Pipeline configuration: blueprint catalog and per-run config dataclass."""

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, ClassVar

from pydantic import BaseModel


class BlueprintSpec(BaseModel):
    name: str
    description: str
    stages: list[str]

    def model_post_init(self, _context: Any) -> None:
        if not self.stages:
            raise ValueError(f"Blueprint '{self.name}' requires 'stages'")

    def to_dict(self) -> dict[str, Any]:
        return {"description": self.description, "stages": self.stages}


# ── Project → Target Directory Mappings ───────────────────────────────────
PROJECT_ROOTS: dict[str, str] = {
    "default": ".",
    "rufkis": "/Users/jocham/programming/projects/mediusfy/platform/kube/view",
}


# ── Blueprint Catalog ─────────────────────────────────────────────────────
_BLUEPRINT_SPECS: list[BlueprintSpec] = [
    BlueprintSpec(
        name="new_feature",
        description="Full SDLC: BA → Advisory → Implementation → Quality Gate",
        stages=["ba", "advisory", "implementation", "quality_gate"],
    ),
    BlueprintSpec(
        name="quick_backend",
        description="Backend-only: Implementation → Review",
        stages=["implementation", "quality_gate"],
    ),
    BlueprintSpec(
        name="docs_update",
        description="Documentation: Implementation (docs agent) → Review",
        stages=["implementation", "quality_gate"],
    ),
    BlueprintSpec(
        name="security_review",
        description="Security audit: Review (security agent)",
        stages=["quality_gate"],
    ),
    BlueprintSpec(
        name="langgraph_full",
        description="Full SDLC via LangGraph state machine with retry loops",
        stages=["ba", "advisory", "implementation", "quality_gate"],
    ),
    BlueprintSpec(
        name="langgraph_quick",
        description="Backend-only via LangGraph with test-retry cycle",
        stages=["implementation", "quality_gate"],
    ),
]

BLUEPRINTS: dict[str, dict[str, Any]] = {bp.name: bp.to_dict() for bp in _BLUEPRINT_SPECS}


@dataclass
class PipelineConfig:
    project: str = "default"
    step: str = "all"
    blueprint: str = "langgraph_full"
    resume: bool = False
    auto_yes: bool = False
    dry_run: bool = False
    requirement: str | None = None
    target_root: str = field(default=".")

    blueprints: ClassVar[dict[str, dict[str, Any]]] = BLUEPRINTS

    def __post_init__(self):
        self.target_root = PROJECT_ROOTS.get(self.project, self.project)
        self._validate_blueprint()

    def _validate_blueprint(self):
        if self.blueprint not in BLUEPRINTS:
            raise ValueError(f"Unknown blueprint '{self.blueprint}'. Available: {', '.join(BLUEPRINTS)}")

    def output_dir(self, base: Path = Path("./generated-app")) -> Path:
        return base / self.project
