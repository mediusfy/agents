import argparse
import asyncio
import logging

from orchestration.agents.registration import register_all_agents
from orchestration.healthcheck import assert_startup_checks
from orchestration.observability import configure_observability
from orchestration.pipeline.config import BLUEPRINTS, STAGES, Framework, PipelineConfig
from orchestration.pipeline.factory import build_pipeline
from orchestration.registry import registry

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
logger = logging.getLogger(__name__)

# All valid pipeline steps — both stage names AND individual agent names
STEP_CHOICES = [
    STAGES.BA,
    STAGES.ADVISORY,
    STAGES.IMPLEMENTATION,
    "backend",
    "frontend",
    "database",
    "test",
    "devops",
    "docs",
    STAGES.QUALITY_GATE,
    "sre",
    "review",
    "security",
    "all",
]

# Available pipeline blueprints (sourced from the canonical catalog)
BLUEPRINT_CHOICES = list(BLUEPRINTS.keys())
FRAMEWORK_CHOICES = [f.value for f in Framework]


async def main(
    project: str,
    step: str = "all",
    blueprint: str = "new_feature",
    framework: str = "",
    resume: bool = False,
    auto_yes: bool = False,
    dry_run: bool = False,
    requirement: str | None = None,
):
    configure_observability()
    assert_startup_checks()
    register_all_agents()

    bp = BLUEPRINTS[blueprint]
    resolved_framework = framework or bp.get("framework", "legacy")

    logger.info(f"--- Orgitration Pipeline: {blueprint} (Project: {project}) ---")
    logger.info(f"Blueprint: {bp['description']}")
    logger.info(f"Framework: {resolved_framework}")
    logger.info(f"Registered agents: {registry.list_agents()}")

    config = PipelineConfig(
        project=project,
        step=step,
        blueprint=blueprint,
        framework=resolved_framework,
        resume=resume,
        auto_yes=auto_yes,
        dry_run=dry_run,
        requirement=requirement,
    )

    pipeline = build_pipeline(config)
    await pipeline.execute()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Orgitration Multi-Agent Pipeline")

    blueprints_help = []
    for bp_name, bp_cfg in BLUEPRINTS.items():
        blueprints_help.append(f"  {bp_name}: {bp_cfg['stages']} \u2014 {bp_cfg['description']}")

    parser.add_argument(
        "--blueprint",
        choices=BLUEPRINT_CHOICES,
        default="new_feature",
        help="Pipeline blueprint to run:\n" + "\n".join(blueprints_help),
    )
    parser.add_argument(
        "--step",
        choices=STEP_CHOICES,
        default="all",
        help="Pipeline step or agent name to run (routed to containing stage)",
    )
    parser.add_argument(
        "--framework",
        choices=FRAMEWORK_CHOICES,
        default="",
        help="Override framework from blueprint (langgraph | crewai | autogen | composite | legacy)",
    )
    parser.add_argument(
        "--project", type=str, default="default", help="Project name to isolate outputs and checkpoints"
    )
    parser.add_argument("--requirement", type=str, default=None, help="Custom requirement text")
    parser.add_argument("--resume", action="store_true", help="Resume from last checkpoint")
    parser.add_argument("--yes", action="store_true", help="Skip human-in-the-loop confirmation")
    parser.add_argument("--dry-run", action="store_true", help="Run pipeline with mock data (no LLM calls)")
    args = parser.parse_args()

    asyncio.run(
        main(
            project=args.project,
            step=args.step,
            blueprint=args.blueprint,
            framework=args.framework,
            resume=args.resume,
            auto_yes=args.yes,
            dry_run=args.dry_run,
            requirement=args.requirement,
        )
    )
