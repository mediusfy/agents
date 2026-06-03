import asyncio
import logging

from openclaw.models.core import EventTrigger, PipelineState, UserStory
from openclaw.pipeline.config import PipelineConfig
from openclaw.registry import registry
from openclaw.session_recorder import recorder
from openclaw.stages.base import StageRunner

logger = logging.getLogger(__name__)


class BAStage(StageRunner):
    async def run(self, state: PipelineState, config: PipelineConfig) -> PipelineState:
        logger.info("--- Running BA Stage ---")

        if config.dry_run:
            logger.info("DRY RUN: Using mock BA data.")
            state.user_stories = [
                UserStory(
                    id="US-001",
                    title="Process Payment",
                    gherkin=(
                        "Given a valid payment request\nWhen the system processes it\nThen it emits PaymentSucceeded"
                    ),
                    event_triggers=[EventTrigger(id="evt-1", name="PaymentSucceeded", description="Payment processed")],
                ),
            ]
            state.stage = "ba"
            return state

        from openclaw.adapters.workspace import WorkspaceContext

        workspace = WorkspaceContext()
        md_context = workspace.get_markdown_context()

        semaphore = asyncio.Semaphore(10)
        raw_requirements = config.requirement or "Build a standard service."

        prompt = f"Process these requirements: {raw_requirements}"
        if md_context:
            prompt += f"\n\nAdhere to the following local guidelines:\n{md_context}"

        async with recorder.record_span(
            run_id=state.run_id,
            agent_name="ba",
            pipeline_stage="ba",
            prompt=prompt,
            context_summary=raw_requirements,
        ):
            ba_agent = registry.get("ba")
            ba_result = await self.provider.run_agent(semaphore, "ba", ba_agent, prompt)
            output = getattr(ba_result, "output", [])
            state.user_stories = output if isinstance(output, list) else []

            if not state.user_stories:
                logger.warning("BA returned no user stories. Exiting.")
                return state

            logger.info(f"BA generated {len(state.user_stories)} stories:")
            for us in state.user_stories:
                logger.info(f"  [{us.id}] {us.title}")

        state.stage = "ba"
        return state
