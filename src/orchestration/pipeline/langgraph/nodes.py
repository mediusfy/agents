import logging

from orchestration.adapters.agents import AgentProviderPort
from orchestration.models.core import FailureReport, PipelineState
from orchestration.pipeline.config import PipelineConfig
from orchestration.session_recorder import recorder
from orchestration.stages.advisory_stage import AdvisoryStage
from orchestration.stages.ba_stage import BAStage
from orchestration.stages.implementation_stage import ImplementationStage
from orchestration.stages.merge_stage import MergeStage
from orchestration.stages.quality_gate_stage import QualityGateStage

logger = logging.getLogger(__name__)


def _make_error(state: PipelineState, agent_name: str, message: str) -> dict:
    return {
        "errors": [*state.errors, f"{agent_name}: {message}"],
        "failure_report": FailureReport(
            source=agent_name,
            error_type="runtime_error",
            trace=message,
        ),
    }


async def ba_node(
    state: PipelineState,
    config: PipelineConfig,
    provider: AgentProviderPort,
) -> dict:
    stage = BAStage()
    stage.agent_provider = provider
    async with recorder.record_span(
        run_id=state.run_id,
        agent_name="ba",
        pipeline_stage="ba",
        prompt=config.requirement or "",
    ) as rec:
        try:
            new_state = await stage.run(state, config)
            rec.set_output(new_state)
            if not new_state.user_stories:
                logger.warning("BA returned no stories")
            return {"user_stories": new_state.user_stories, "stage": "ba", "errors": new_state.errors}
        except Exception as e:
            logger.error(f"BA stage failed: {e}")
            return _make_error(state, "ba", str(e))


async def advisory_node(
    state: PipelineState,
    config: PipelineConfig,
    provider: AgentProviderPort,
) -> dict:
    stage = AdvisoryStage()
    stage.agent_provider = provider
    async with recorder.record_span(
        run_id=state.run_id,
        agent_name="advisory",
        pipeline_stage="advisory",
        prompt="\n".join(s.gherkin for s in (state.user_stories or [])),
    ) as rec:
        try:
            new_state = await stage.run(state, config)
            rec.set_output(new_state)
            return {
                "advisory_results": new_state.advisory_results,
                "cto_approved": new_state.cto_approved,
                "stage": "advisory",
            }
        except Exception as e:
            logger.error(f"Advisory stage failed: {e}")
            return _make_error(state, "advisory", str(e))


async def implementation_node(
    state: PipelineState,
    config: PipelineConfig,
    provider: AgentProviderPort,
) -> dict:
    stage = ImplementationStage()
    stage.agent_provider = provider
    async with recorder.record_span(
        run_id=state.run_id,
        agent_name="implementation",
        pipeline_stage="implementation",
        prompt=config.requirement or "",
    ) as rec:
        try:
            new_state = await stage.run(state, config)
            rec.set_output(new_state)
            return {
                "artifacts": new_state.artifacts,
                "failure_report": new_state.failure_report,
                "feedback": new_state.feedback,
                "stage": "implementation",
                "refinement_attempts": state.refinement_attempts + 1,
            }
        except Exception as e:
            logger.error(f"Implementation stage failed: {e}")
            return _make_error(state, "implementation", str(e))


async def quality_gate_node(
    state: PipelineState,
    config: PipelineConfig,
    provider: AgentProviderPort,
) -> dict:
    stage = QualityGateStage()
    stage.agent_provider = provider
    async with recorder.record_span(
        run_id=state.run_id,
        agent_name="quality_gate",
        pipeline_stage="quality_gate",
        prompt="Quality gate check",
    ) as rec:
        try:
            new_state = await stage.run(state, config)
            rec.set_output(new_state)
            return {
                "approved": new_state.approved,
                "failure_report": new_state.failure_report,
                "feedback": new_state.feedback,
                "stage": "quality_gate",
            }
        except Exception as e:
            logger.error(f"Quality gate failed: {e}")
            return _make_error(state, "quality_gate", str(e))


async def merge_node(
    state: PipelineState,
    config: PipelineConfig,
) -> dict:
    stage = MergeStage()
    async with recorder.record_span(
        run_id=state.run_id,
        agent_name="merge",
        pipeline_stage="merge",
        prompt="Merge artifacts into project",
    ) as rec:
        try:
            new_state = await stage.run(state, config)
            rec.set_output(new_state)
            return {"stage": "merge", "approved": new_state.approved}
        except Exception as e:
            logger.error(f"Merge failed: {e}")
            return _make_error(state, "merge", str(e))
