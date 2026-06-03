from dataclasses import dataclass


@dataclass
class PipelineConfig:
    project: str = "default"
    step: str = "all"
    resume: bool = False
    auto_yes: bool = False
    dry_run: bool = False
    requirement: str | None = None
