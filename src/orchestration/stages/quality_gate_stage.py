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
        from orchestration.context_engine import retrieve_context

        sre_ctx = await retrieve_context("sre", "Provision infrastructure and apply Helm charts.")
        sre_prompt = "Provision infrastructure and apply Helm charts."
        if sre_ctx:
            sre_prompt += f"\n\nRetrieved SRE Context/ADRs:\n{sre_ctx}"

        async with recorder.record_span(
            run_id=state.run_id,
            agent_name="sre",
            pipeline_stage="quality_gate",
            prompt=sre_prompt,
        ) as rec:
            sre_res = await self.provider.run_agent(semaphore, "sre", registry.get("sre"), sre_prompt)
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

        logger.info("Running Multi-Perspective Verification Gates (security + quality_gate + review in parallel)...")
        from orchestration.context_engine import retrieve_context

        async def _run_security():
            sec_ctx = await retrieve_context("security", full_text)
            prompt = f"Audit the following code for vulnerabilities:\n{full_text}"
            if sec_ctx:
                prompt += f"\n\nRetrieved Security Context:\n{sec_ctx}"
            async with recorder.record_span(
                run_id=state.run_id,
                agent_name="security",
                pipeline_stage="quality_gate",
                prompt=prompt,
            ) as rec:
                res = await self.provider.run_agent(semaphore, "security", registry.get("security"), prompt)
                rec.set_output(res)
                r = res.output
                logger.info(f"Security: passed={r.passed}, score={r.score}")
                return r.passed, getattr(r, "vulnerabilities", r.feedback if hasattr(r, "feedback") else [])

        async def _run_quality_gate():
            qg_ctx = await retrieve_context("quality_gate", full_text)
            prompt = f"Perform quality gate check on these artifacts:\n{full_text}"
            if qg_ctx:
                prompt += f"\n\nRetrieved Quality Gate Rules:\n{qg_ctx}"
            async with recorder.record_span(
                run_id=state.run_id,
                agent_name="quality_gate",
                pipeline_stage="quality_gate",
                prompt=prompt,
            ) as rec:
                res = await self.provider.run_agent(semaphore, "quality_gate", registry.get("quality_gate"), prompt)
                rec.set_output(res)
                r = res.output
                logger.info(f"Quality Gate: passed={r.passed}, complexity={r.complexity_score}")
                return r.passed, r.feedback

        async def _run_review():
            prompt = (
                f"Review the following generated artifacts:\n{full_text}\n"
                "Ensure code is robust, secure, and meets all criteria."
            )
            review_ctx = await retrieve_context("review", full_text)
            if review_ctx:
                prompt += f"\n\nRetrieved Review Context/Conventions:\n{review_ctx}"
            async with recorder.record_span(
                run_id=state.run_id,
                agent_name="review",
                pipeline_stage="quality_gate",
                prompt=prompt,
            ) as rec:
                res = await self.provider.run_agent(semaphore, "review", registry.get("review"), prompt)
                rec.set_output(res)
                r = res.output
                logger.info(f"Review: approved={r.approved}, risk={r.risk_level}, security_score={r.security_score}")
                return r.approved, r.feedback

        results = await asyncio.gather(
            _run_security(), _run_quality_gate(), _run_review(), return_exceptions=True
        )

        failures: list[str] = []
        gate_names = ["security", "quality_gate", "review"]
        for name, result in zip(gate_names, results):
            if isinstance(result, BaseException):
                failures.append(f"{name}: {result}")
            else:
                passed, feedback = result
                if not passed:
                    fb = "; ".join(feedback) if isinstance(feedback, list) else str(feedback)
                    failures.append(f"{name}: {fb}")

        if not failures:
            logger.info("All verification gates passed.")
            state.approved = True
            state.feedback = None
            state.failure_report = None
        else:
            logger.warning(f"Verification gates failed: {len(failures)}/{len(gate_names)}")
            state.feedback = "Multi-perspective gate failures:\n" + "\n".join(failures)
            state.failure_report = FailureReport(
                source="multi_perspective_gate",
                error_type="verification_failure",
                trace=state.feedback,
            )
            state.approved = False

        state.stage = "quality_gate"
        return state
