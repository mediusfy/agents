import logging

from openclaw.adapters.agents import PydanticAIAgentProvider
from openclaw.adapters.state_repository import LocalDiskStateRepository
from openclaw.adapters.workspace import ArtifactStorageAdapter, WorkspaceContext
from openclaw.checkpoint import CheckpointManager
from openclaw.models.core import PipelineState
from openclaw.pipeline.config import PipelineConfig
from openclaw.stages.base import StageRunner

logger = logging.getLogger(__name__)


class OpenClawPipeline:
    def __init__(self, config: PipelineConfig):
        self.config = config

        # Initialize the state repository port with the local disk adapter
        repository = LocalDiskStateRepository(config.project)
        self.checkpoint_mgr = CheckpointManager(repository=repository)

        self.workspace = WorkspaceContext()
        self.artifact_writer = ArtifactStorageAdapter("generated-app")

        self.agent_provider = PydanticAIAgentProvider()

        import uuid

        self.state = PipelineState(run_id=f"run-{uuid.uuid4().hex[:8]}", stage="init")

        # Stages mapping
        self.stages: dict[str, StageRunner] = {}

    def register_stage(self, name: str, stage: StageRunner):
        if stage.agent_provider is None:
            stage.agent_provider = self.agent_provider
        self.stages[name] = stage

    async def execute(self):
        logger.info(f"Starting OpenClaw Pipeline for project: {self.config.project}")

        # Determine execution plan based on step
        ordered_stage_names = ["ba", "advisory", "implementation", "quality_gate"]

        if self.config.step != "all":
            if self.config.step in ordered_stage_names:
                ordered_stage_names = [self.config.step]
            else:
                logger.error(f"Unknown step: {self.config.step}")
                return

        for stage_name in ordered_stage_names:
            if stage_name not in self.stages:
                logger.warning(f"Stage {stage_name} not registered. Skipping.")
                continue

            # 1. Resume Checkpoint Logic
            if self.config.resume and self.checkpoint_mgr.stage_exists(stage_name):
                logger.info(f"Resuming stage {stage_name} from checkpoint...")
                self.state = self.checkpoint_mgr.load(stage_name)
                continue

            logger.info(f"Executing stage: {stage_name}")

            # 2. Execute Pure Stage Logic
            try:
                if stage_name == "implementation":
                    # Implementation and Quality Gate are tightly coupled in a retry loop
                    from openclaw.settings import settings

                    max_retries = settings.max_retries if self.config.step == "all" else 1

                    for attempt in range(max_retries):
                        logger.info(f"--- Implementation Loop Attempt {attempt + 1}/{max_retries} ---")
                        self.state = await self.stages["implementation"].run(self.state, self.config)

                        # If test suite failed (caught internally), retry implementation directly
                        if not getattr(self.state, "approved", True) and getattr(self.state, "feedback", None):
                            continue

                        # If implementation succeeded, proceed to quality gate
                        if "quality_gate" in self.stages:
                            self.state = await self.stages["quality_gate"].run(self.state, self.config)

                        if getattr(self.state, "approved", False):
                            break

                    # If we explicitly asked for just implementation step, don't run quality gate next
                    if self.config.step == "all":
                        # We handled quality_gate inside the loop, we can pop it or skip it in the outer loop
                        pass
                elif stage_name == "quality_gate" and self.config.step == "all":
                    # Handled inside the implementation retry loop
                    continue
                else:
                    self.state = await self.stages[stage_name].run(self.state, self.config)

            except Exception as e:
                logger.error(f"Pipeline crashed during stage '{stage_name}': {e}")
                raise

            # 3. Centralized Checkpoint Commit
            self.checkpoint_mgr.save(stage_name, self.state)

        # 4. Final Adapter Logic
        self.artifact_writer.write_artifacts(self.state.artifacts)
