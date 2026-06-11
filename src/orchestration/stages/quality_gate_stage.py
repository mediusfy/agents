import asyncio
import logging

from orchestration.models.core import FailureReport, PipelineState
from orchestration.pipeline.config import PipelineConfig
from orchestration.registry import registry
from orchestration.session_recorder import recorder
from orchestration.settings import settings
from orchestration.stages.base import StageRunner
from orchestration.utils import format_artifacts
from orchestration.validators import CodeValidator

logger = logging.getLogger(__name__)


class QualityGateStage(StageRunner):
    async def run(self, state: PipelineState, config: PipelineConfig) -> PipelineState:
        logger.info("--- Running Quality Gate Stage ---")

        if config.dry_run:
            logger.info("DRY RUN: Skipping Quality Gate checks.")
            state.approved = True
            state.stage = "quality_gate"
            return state

        semaphore = asyncio.Semaphore(settings.max_concurrent_llm_calls)
        artifacts = state.artifacts or []

        logger.info("Running SRE Agent...")
        async with recorder.record_span(
            run_id=state.run_id,
            agent_name="sre",
            pipeline_stage="quality_gate",
            prompt="Provision infrastructure and apply Helm charts for the services.",
        ) as rec:
            sre_res = await self.provider.run_agent(
                semaphore, "sre", registry.get("sre"), "Provision infrastructure and apply Helm charts."
            )
            rec.set_output(sre_res)
            # Create a clean copy to avoid mutating the agent's returned artifact
            sre_artifact = sre_res.output.model_copy(deep=True)
            sre_artifact.metadata["user_story_id"] = "infrastructure"
            sre_artifact.agent_name = "infrastructure"
            artifacts.append(sre_artifact)

        full_text = format_artifacts(artifacts, max_chars=80_000)

        logger.info("Running Code Validation...")
        if not await CodeValidator.run_all_async(artifacts):
            logger.warning("Code validation failed.")
            state.feedback = "Code validation failed during the Quality Gate. Please fix compilation issues."
            state.failure_report = FailureReport(
                source="quality_gate_validation",
                error_type="compilation",
                trace=state.feedback,
            )
            state.approved = False
            return state

        logger.info("Running Security Audit...")
        async with recorder.record_span(
            run_id=state.run_id,
            agent_name="security",
            pipeline_stage="quality_gate",
            prompt=f"Audit the following code for vulnerabilities:\n{full_text}",
        ) as rec:
            sec_res = await self.provider.run_agent(
                semaphore,
                "security",
                registry.get("security"),
                f"Audit the following code for vulnerabilities:\n{full_text}",
            )
            rec.set_output(sec_res)
            sec_result = sec_res.output
            logger.info(f"Security: passed={sec_result.passed}, score={sec_result.score}")
            if not sec_result.passed:
                logger.warning("Security audit failed.")
                state.feedback = "Security audit failed. Resolve these vulnerabilities: \n" + "\n".join(
                    sec_result.vulnerabilities
                )
                state.failure_report = FailureReport(
                    source="security_audit",
                    error_type="security",
                    trace=state.feedback,
                )
                state.approved = False
                return state

        logger.info("Running Quality Gate...")
        async with recorder.record_span(
            run_id=state.run_id,
            agent_name="quality_gate",
            pipeline_stage="quality_gate",
            prompt="Perform quality gate check on these artifacts:",
        ) as rec:
            q_res = await self.provider.run_agent(
                semaphore,
                "quality_gate",
                registry.get("quality_gate"),
                f"Perform quality gate check on these artifacts:\n{full_text}",
            )
            rec.set_output(q_res)
            q_result = q_res.output
            logger.info(f"Quality Gate: passed={q_result.passed}, complexity={q_result.complexity_score}")
            if not q_result.passed:
                logger.warning("Quality Gate rejected.")
                state.feedback = "\n".join(q_result.feedback)
                state.failure_report = FailureReport(
                    source="quality_gate_agent",
                    error_type="quality_check",
                    trace=state.feedback,
                )
                state.approved = False
                return state

        logger.info("Running Board of Review...")
        review_prompt = (
            f"Review the following generated artifacts:\n{full_text}\n"
            "Ensure code is robust, secure, and meets all criteria."
        )
        if state.feedback:
            review_prompt += f"\n\nAddress previous feedback: {state.feedback}"

        async with recorder.record_span(
            run_id=state.run_id,
            agent_name="review",
            pipeline_stage="quality_gate",
            prompt=review_prompt,
        ) as rec:
            review_res = await self.provider.run_agent(semaphore, "review", registry.get("review"), review_prompt)
            rec.set_output(review_res)
            result = review_res.output
            logger.info(
                f"Review: approved={result.approved}, risk={result.risk_level}, security_score={result.security_score}"
            )

            if result.approved:
                state.approved = True
                state.feedback = None
                state.failure_report = None
            else:
                logger.warning("Review rejected. Setting feedback for implementation retry.")
                state.feedback = "\n".join(result.feedback)
                state.failure_report = FailureReport(
                    source="review_agent",
                    error_type="review_rejection",
                    trace=state.feedback,
                )
                state.approved = False

        state.stage = "quality_gate"
        return state
