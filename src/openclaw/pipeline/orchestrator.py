import logging
import uuid

from openclaw.adapters.agents import PydanticAIAgentProvider
from openclaw.adapters.state_repository import LocalDiskStateRepository
from openclaw.adapters.workspace import ArtifactStorageAdapter, WorkspaceContext
from openclaw.checkpoint import CheckpointManager
from openclaw.models.core import PipelineState
from openclaw.pipeline.config import PipelineConfig
from openclaw.stages.base import StageRunner

logger = logging.getLogger(__name__)


# ── Step routing: single-agent names → their containing pipeline stage ─────
_STEP_TO_STAGE = {
    "ba": "ba",
    "advisory": "advisory",
    "implementation": "implementation",
    "backend": "implementation",
    "frontend": "implementation",
    "database": "implementation",
    "test": "implementation",
    "devops": "implementation",
    "docs": "implementation",
    "quality_gate": "quality_gate",
    "sre": "quality_gate",
    "review": "quality_gate",
    "security": "quality_gate",
    "all": "all",
}


class OpenClawPipeline:
    def __init__(self, config: PipelineConfig):
        self.config = config

        # Initialize state repository with project isolation
        repository = LocalDiskStateRepository(config.project)
        self.checkpoint_mgr = CheckpointManager(repository=repository)

        # Workspace context pointing at the target project for repo-awareness
        self.workspace = WorkspaceContext(root_dir=config.target_root)
        self.artifact_writer = ArtifactStorageAdapter(str(config.output_dir()))

        self.agent_provider = PydanticAIAgentProvider()

        self.state = PipelineState(run_id=f"run-{uuid.uuid4().hex[:8]}", stage="init")

        # Stages mapping
        self.stages: dict[str, StageRunner] = {}

    def register_stage(self, name: str, stage: StageRunner):
        if stage.agent_provider is None:
            stage.agent_provider = self.agent_provider
        self.stages[name] = stage

    async def execute(self):
        logger.info(f"Starting OpenClaw Pipeline for project: {self.config.project}")
        logger.info(f"Target root: {self.config.target_root}")
        logger.info(f"Output dir: {self.config.output_dir()}")
        logger.info(f"Registered stages: {list(self.stages.keys())}")

        # Resolve step name → pipeline stage name
        stage = _STEP_TO_STAGE.get(self.config.step)
        if stage is None:
            logger.error(f"Unknown step: {self.config.step}. Valid steps: {list(_STEP_TO_STAGE.keys())}")
            return

        ordered_stage_names = ["ba", "advisory", "implementation", "quality_gate"]
        if stage != "all":
            ordered_stage_names = [stage]

        for stage_name in ordered_stage_names:
            if stage_name not in self.stages:
                logger.warning(f"Stage {stage_name} not registered. Skipping.")
                continue

            # Resume Checkpoint Logic
            if self.config.resume and self.checkpoint_mgr.stage_exists(stage_name):
                logger.info(f"Resuming stage {stage_name} from checkpoint...")
                self.state = self.checkpoint_mgr.load(stage_name)
                continue

            logger.info(f"Executing stage: {stage_name}")

            try:
                if stage_name == "implementation":
                    from openclaw.settings import settings

                    max_retries = settings.max_retries if self.config.step == "all" else 1

                    for attempt in range(max_retries):
                        logger.info(f"--- Implementation Loop Attempt {attempt + 1}/{max_retries} ---")
                        self.state = await self.stages["implementation"].run(self.state, self.config)

                        # Test suite failed — retry implementation
                        failure = getattr(self.state, "failure_report", None)
                        if failure and failure.source == "test_suite":
                            logger.info("Test failure detected — retrying implementation with feedback.")
                            continue

                        # Proceed to quality gate
                        if "quality_gate" in self.stages:
                            self.state = await self.stages["quality_gate"].run(self.state, self.config)

                        if getattr(self.state, "approved", False):
                            logger.info("Quality gate passed — breaking retry loop.")
                            break

                elif stage_name == "quality_gate" and self.config.step == "all":
                    # Handled inside the implementation retry loop
                    continue
                else:
                    self.state = await self.stages[stage_name].run(self.state, self.config)

            except Exception as e:
                logger.error(f"Pipeline crashed during stage '{stage_name}': {e}")
                raise

            # Checkpoint commit
            self.checkpoint_mgr.save(stage_name, self.state)

        # Final artifact flush
        self.artifact_writer.write_artifacts(self.state.artifacts)

        # Run merge stage: apply artifacts into the real project tree
        if stage == "all" and getattr(self.state, "approved", False):
            from openclaw.stages.merge_stage import MergeStage
            merge = MergeStage()
            merge.agent_provider = self.agent_provider
            logger.info("Pipeline approved — running merge stage to apply artifacts into target project.")
            self.state = await merge.run(self.state, self.config)
