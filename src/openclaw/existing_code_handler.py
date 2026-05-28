"""Entry point for modifying EXISTING Go codebases.

Chains: service_engineer → test_eng → quality_gate → review
Each step validates the previous one before proceeding.
"""

import contextlib
import logging
import os
import time
from dataclasses import dataclass, field
from typing import Any

import logfire

from openclaw.models.core import Artifact
from openclaw.registry import registry
from openclaw.telemetry import telemetry
from openclaw.utils import format_artifacts

logger = logging.getLogger(__name__)


@dataclass
class ExistingCodeResult:
    """Result of an existing code modification pipeline run."""

    passed: bool = False
    changed_files: list[str] = field(default_factory=list)
    artifacts: list[Artifact] = field(default_factory=list)
    test_files: list[str] = field(default_factory=list)
    quality_gate_score: int = 0
    quality_gate_feedback: list[str] = field(default_factory=list)
    review_approved: bool = False
    review_risk: str = ""
    errors: list[str] = field(default_factory=list)


async def _run_stage(
    stage_name: str,
    agent_name: str,
    prompt: str,
    span_attrs: dict | None = None,
) -> tuple[Any, bool]:
    """Run a single pipeline stage with Logfire span + JSONL telemetry.

    Returns:
        (result, success) — result is the agent output or None, success is a bool.
    """
    span_attrs = span_attrs or {}
    agent = registry.get(agent_name)
    start = time.time()
    success = False
    try:
        with logfire.span(
            f"existing_code.{stage_name}",
            agent_name=agent_name,
            prompt_length=len(prompt),
            **span_attrs,
            _level="info",
        ):
            result = await agent.run(prompt)
            success = True
            return result, success
    except Exception:
        raise
    finally:
        duration = time.time() - start
        with contextlib.suppress(Exception):
            await telemetry.log_call(agent_name, duration, success, metadata=span_attrs)


async def run_existing_code_pipeline(
    change_description: str,
    codebase_path: str,
    run_tests: bool = True,
    run_quality_gate: bool = True,
    run_review: bool = True,
) -> ExistingCodeResult:
    """Modify existing Go code through a multi-agent pipeline.

    Args:
        change_description: What to change and why (e.g., "Add tracing to the
            ProcessMessage handler in internal/service/message.go")
        codebase_path: Absolute path to the existing codebase root.
        run_tests: Whether to generate/update tests via test_eng.
        run_quality_gate: Whether to check for over-engineering.
        run_review: Whether to run final review.

    Returns:
        ExistingCodeResult with pass/fail, changed files, and check results.
    """
    result = ExistingCodeResult()

    logger.info("=== Existing Code Pipeline ===")
    logger.info("Change: %s", change_description)

    # Sandbox the service_engineer agent's read_file/list_directory tools to
    # the requested codebase root (or CWD when unspecified). The agent reads
    # this via os.environ in service_engineer._sandbox_root().
    if codebase_path:
        os.environ["OPENCLAW_CODEBASE_ROOT"] = os.path.realpath(codebase_path)
    else:
        os.environ.pop("OPENCLAW_CODEBASE_ROOT", None)

    # Service Engineer
    logger.info("Service Engineer — implementing changes...")
    with logfire.span(
        "existing_code.pipeline",
        stage="service_engineer",
        change_description_length=len(change_description),
        codebase_path=codebase_path or "auto-detect",
        _level="info",
    ):
        try:
            eng_prompt = (
                f"Modify the codebase at {codebase_path} to implement this change:\n\n"
                f"{change_description}\n\n"
                f"Read the relevant existing files first using the read_file tool. "
                f"Understand the patterns before modifying. Return ONLY the changed files."
            )
            eng_result, _ = await _run_stage(
                "service_engineer",
                "service_engineer",
                eng_prompt,
                {"codebase_path": codebase_path or "auto-detect"},
            )
        except Exception as e:
            msg = f"Service Engineer failed: {e}"
            logger.error(msg)
            result.errors.append(msg)
            result.passed = False
            return result

    eng_artifact = eng_result.output
    result.artifacts.append(eng_artifact)
    result.changed_files = list(eng_artifact.files.keys())
    logger.info("Changed files: %s", result.changed_files)

    if not result.changed_files:
        logger.warning("Service Engineer returned no changed files.")
        result.passed = True
        return result

    # Test Engineer
    if run_tests:
        logger.info("Test Engineer — generating tests...")
        with logfire.span(
            "existing_code.pipeline",
            stage="test_engineer",
            changed_files_count=len(result.changed_files),
            _level="info",
        ):
            try:
                test_preview = format_artifacts(result.artifacts, max_chars=15_000, include_agent_header=False)
                test_prompt = (
                    f"Using the generate_go_table_driven_tests tool, write tests for "
                    f"the changed functions in these files:\n\n{test_preview}\n\n"
                    f"Read each changed source file to identify the function signatures, "
                    f"then generate table-driven tests."
                )
                test_result, _ = await _run_stage(
                    "test_engineer",
                    "test_eng",
                    test_prompt,
                    {"changed_files_count": len(result.changed_files)},
                )
                if hasattr(test_result.output, "files"):
                    result.artifacts.append(test_result.output)
                    result.test_files = list(test_result.output.files.keys())
                    logger.info("Test files: %s", result.test_files)
            except Exception as e:
                msg = f"Test Engineer failed: {e}"
                logger.warning(msg)
                result.errors.append(msg)

    # Quality Gate
    if run_quality_gate:
        logger.info("Quality Gate — checking over-engineering...")
        with logfire.span(
            "existing_code.pipeline",
            stage="quality_gate",
            artifact_count=len(result.artifacts),
            _level="info",
        ):
            try:
                qg_preview = format_artifacts(result.artifacts, max_chars=30_000, include_agent_header=False)
                qg_prompt = (
                    f"Perform a quality gate check on these code changes. "
                    f"Check for over-engineering, premature abstraction, "
                    f"reinventing the wheel, and unnecessary complexity.\n\n"
                    f"{qg_preview}"
                )
                qg_result, _ = await _run_stage(
                    "quality_gate",
                    "quality_gate",
                    qg_prompt,
                    {"artifact_count": len(result.artifacts)},
                )
                qg_data = qg_result.output
                result.quality_gate_score = qg_data.complexity_score
                result.quality_gate_feedback = qg_data.feedback
                logger.info(
                    "Quality Gate: passed=%s, complexity=%s",
                    qg_data.passed,
                    qg_data.complexity_score,
                )
                if not qg_data.passed:
                    logger.warning("Quality Gate rejected. Feedback: %s", qg_data.feedback)
                    result.passed = False
                    return result
            except Exception as e:
                msg = f"Quality Gate failed: {e}"
                logger.warning(msg)
                result.errors.append(msg)

    # Board of Review
    if run_review:
        logger.info("Board of Review — final approval...")
        with logfire.span(
            "existing_code.pipeline",
            stage="review",
            artifact_count=len(result.artifacts),
            _level="info",
        ):
            try:
                review_preview = format_artifacts(result.artifacts, max_chars=40_000, include_agent_header=False)
                review_prompt = (
                    f"Review these code changes for production readiness. "
                    f"Check for correctness, security issues, architecture fit, "
                    f"and CODING_STANDARDS compliance.\n\n{review_preview}"
                )
                review_result, _ = await _run_stage(
                    "review",
                    "review",
                    review_prompt,
                    {"artifact_count": len(result.artifacts)},
                )
                review_data = review_result.output
                result.review_approved = review_data.approved
                result.review_risk = review_data.risk_level.value
                logger.info(
                    "Review: approved=%s, risk=%s",
                    review_data.approved,
                    review_data.risk_level,
                )
                if not review_data.approved:
                    logger.warning("Review rejected: %s", review_data.feedback)
                    result.errors.extend(review_data.feedback)
            except Exception as e:
                msg = f"Review failed: {e}"
                logger.warning(msg)
                result.errors.append(msg)

    result.passed = result.review_approved if run_review else True
    return result


def format_result_summary(result: ExistingCodeResult) -> str:
    """Format the pipeline result into a human-readable summary."""
    lines = ["## Existing Code Pipeline Results", "", f"**Status**: {'PASSED' if result.passed else 'FAILED'}"]

    if result.changed_files:
        lines.append("\n**Changed files**:")
        for f in result.changed_files:
            lines.append(f"  - {f}")

    if result.test_files:
        lines.append("\n**Test files**:")
        for f in result.test_files:
            lines.append(f"  - {f}")

    if result.quality_gate_feedback:
        lines.append(f"\n**Quality Gate**: score={result.quality_gate_score}")
        for fb in result.quality_gate_feedback:
            lines.append(f"  - {fb}")

    lines.append(f"\n**Review**: {'approved' if result.review_approved else 'rejected'} (risk: {result.review_risk})")

    if result.errors:
        lines.append("\n**Errors/Warnings**:")
        for e in result.errors:
            lines.append(f"  - {e}")

    return "\n".join(lines)
