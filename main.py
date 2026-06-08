import argparse
import asyncio
import logging

from openclaw.agents.registration import register_all_agents
from openclaw.healthcheck import assert_startup_checks
from openclaw.observability import configure_observability
from openclaw.pipeline.config import PipelineConfig
from openclaw.pipeline.orchestrator import OpenClawPipeline
from openclaw.registry import registry
from openclaw.stages.advisory_stage import AdvisoryStage
from openclaw.stages.ba_stage import BAStage
from openclaw.stages.implementation_stage import ImplementationStage
from openclaw.stages.quality_gate_stage import QualityGateStage

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
logger = logging.getLogger(__name__)

# All valid pipeline steps — both stage names AND individual agent names
STEP_CHOICES = ["ba", "advisory", "implementation", "backend", "frontend", "database", "test", "devops", "docs", "quality_gate", "sre", "review", "security", "all"]

# Available pipeline blueprints (generated from config)
BLUEPRINT_CHOICES = list(PipelineConfig.blueprints.keys())


async def main(
    project: str,
    step: str = "all",
    blueprint: str = "new_feature",
    resume: bool = False,
    auto_yes: bool = False,
    dry_run: bool = False,
    requirement: str | None = None,
):
    configure_observability()
    assert_startup_checks()
    register_all_agents()

    logger.info(f"--- OpenClaw Pipeline: {blueprint} (Project: {project}) ---")
    logger.info(f"Blueprint: {PipelineConfig.blueprints[blueprint]['description']}")
    logger.info(f"Stages: {PipelineConfig.blueprints[blueprint]['stages']}")
    logger.info(f"Registered agents: {registry.list_agents()}")

    config = PipelineConfig(
        project=project,
        step=step,
        blueprint=blueprint,
        resume=resume,
        auto_yes=auto_yes,
        dry_run=dry_run,
        requirement=requirement,
    )

    pipeline = OpenClawPipeline(config)
    pipeline.register_stage("ba", BAStage())
    pipeline.register_stage("advisory", AdvisoryStage())
    pipeline.register_stage("implementation", ImplementationStage())
    pipeline.register_stage("quality_gate", QualityGateStage())

    await pipeline.execute()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="OpenClaw Multi-Agent Pipeline")

    blueprints_help = []
    for bp_name, bp_cfg in PipelineConfig.blueprints.items():
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
            resume=args.resume,
            auto_yes=args.yes,
            dry_run=args.dry_run,
            requirement=args.requirement,
        )
    )
