from dataclasses import dataclass, field
from pathlib import Path

# ── Project → Target Directory Mappings ───────────────────────────────────
# Maps project names to the real source directories so agents can read
# existing code structure before generating new code.
PROJECT_ROOTS: dict[str, str] = {
    "default": ".",
    "rufkis": "/Users/jocham/programming/omni-rufkis/rufkis/kube/view",
}


@dataclass
class PipelineConfig:
    project: str = "default"
    step: str = "all"
    resume: bool = False
    auto_yes: bool = False
    dry_run: bool = False
    requirement: str | None = None
    target_root: str = field(default=".")

    def __post_init__(self):
        """Resolve target_root from project name, falling back to the name itself."""
        self.target_root = PROJECT_ROOTS.get(self.project, self.project)

    def output_dir(self, base: Path = Path("./generated-app")) -> Path:
        """Artifact output directory, isolated by project name."""
        return base / self.project
