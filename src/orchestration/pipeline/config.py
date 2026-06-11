"""Pipeline configuration: blueprint catalog and per-run config dataclass."""

from dataclasses import dataclass, field
from pathlib import Path
from typing import ClassVar

# ── Project → Target Directory Mappings ───────────────────────────────────
# Maps project names to the real source directories so agents can read
# existing code structure before generating new code.
PROJECT_ROOTS: dict[str, str] = {
    "default": ".",
    "rufkis": "/Users/jocham/programming/omni-rufkis/rufkis/kube/view",
}


# ── Blueprint Catalog ─────────────────────────────────────────────────────
# Module-level dict (not a staticmethod) so callers can use standard dict
# operations: ``BLUEPRINTS.keys()``, ``BLUEPRINTS[name]``, iteration, ``in``.
#
# Each blueprint defines which pipeline stages run and in what order.
# The orchestrator uses this to build the stage registry.
BLUEPRINTS: dict[str, dict[str, str | list[str]]] = {
    "new_feature": {
        "description": "Full SDLC: BA → Advisory → Implementation → Quality Gate",
        "stages": ["ba", "advisory", "implementation", "quality_gate"],
    },
    "quick_backend": {
        "description": "Backend-only: Implementation → Review",
        "stages": ["implementation", "quality_gate"],
    },
    "docs_update": {
        "description": "Documentation: Implementation (docs agent) → Review",
        "stages": ["implementation", "quality_gate"],
    },
    "security_review": {
        "description": "Security audit: Review (security agent)",
        "stages": ["quality_gate"],
    },
}


@dataclass
class PipelineConfig:
    project: str = "default"
    step: str = "all"
    blueprint: str = "new_feature"
    resume: bool = False
    auto_yes: bool = False
    dry_run: bool = False
    requirement: str | None = None
    target_root: str = field(default=".")

    # ── Backwards-compatible class-level accessor ─────────────────────────
    # Older call sites read ``PipelineConfig.blueprints`` as if it were a
    # dict. Previously this was a ``@staticmethod`` returning a dict, which
    # silently broke ``.keys()`` / ``in`` / iteration. Exposing it as a
    # ``ClassVar`` bound to the module-level ``BLUEPRINTS`` keeps the old
    # access pattern working while making the canonical data importable.
    #
    # New code should prefer ``from orchestration.pipeline.config import BLUEPRINTS``.
    blueprints: ClassVar[dict[str, dict[str, str | list[str]]]] = BLUEPRINTS

    def __post_init__(self):
        """Resolve target_root from project name, falling back to the name itself."""
        self.target_root = PROJECT_ROOTS.get(self.project, self.project)

    def output_dir(self, base: Path = Path("./generated-app")) -> Path:
        """Artifact output directory, isolated by project name."""
        return base / self.project
