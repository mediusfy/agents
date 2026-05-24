"""Entry point for modifying EXISTING Go codebases.

Chains: service_engineer → test_eng → quality_gate → review
Each step validates the previous one before proceeding.
"""

import logging
from dataclasses import dataclass, field

from openclaw.models.core import Artifact
from openclaw.registry import registry
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

    logger.info("Service Engineer — implementing changes...")
    try:
        service_engineer = registry.get("service_engineer")
        eng_prompt = (
            f"Modify the codebase at {codebase_path} to implement this change:\n\n"
            f"{change_description}\n\n"
            f"Read the relevant existing files first using the read_file tool. "
            f"Understand the patterns before modifying. Return ONLY the changed files."
        )
        eng_result = await service_engineer.run(eng_prompt)
        eng_artifact = eng_result.output
        result.artifacts.append(eng_artifact)
        result.changed_files = list(eng_artifact.files.keys())
        logger.info("Changed files: %s", result.changed_files)
    except Exception as e:
        msg = f"Service Engineer failed: {e}"
        logger.error(msg)
        result.errors.append(msg)
        result.passed = False
        return result

    if not result.changed_files:
        logger.warning("Service Engineer returned no changed files.")
        result.passed = True
        return result

    if run_tests:
        logger.info("Test Engineer — generating tests...")
        try:
            test_eng = registry.get("test_eng")
            test_preview = format_artifacts(result.artifacts, max_chars=15_000, include_agent_header=False)
            test_prompt = (
                f"Using the generate_go_table_driven_tests tool, write tests for "
                f"the changed functions in these files:\n\n{test_preview}\n\n"
                f"Read each changed source file to identify the function signatures, "
                f"then generate table-driven tests."
            )
            test_result = await test_eng.run(test_prompt)
            if hasattr(test_result.output, "files"):
                result.artifacts.append(test_result.output)
                result.test_files = list(test_result.output.files.keys())
                logger.info("Test files: %s", result.test_files)
        except Exception as e:
            msg = f"Test Engineer failed: {e}"
            logger.warning(msg)
            result.errors.append(msg)

    if run_quality_gate:
        logger.info("Quality Gate — checking over-engineering...")
        try:
            quality_gate = registry.get("quality_gate")
            qg_preview = format_artifacts(result.artifacts, max_chars=30_000, include_agent_header=False)
            qg_prompt = (
                f"Perform a quality gate check on these code changes. "
                f"Check for over-engineering, premature abstraction, "
                f"reinventing the wheel, and unnecessary complexity.\n\n"
                f"{qg_preview}"
            )
            qg_result = await quality_gate.run(qg_prompt)
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

    if run_review:
        logger.info("Board of Review — final approval...")
        try:
            review = registry.get("review")
            review_preview = format_artifacts(result.artifacts, max_chars=40_000, include_agent_header=False)
            review_prompt = (
                f"Review these code changes for production readiness. "
                f"Check for correctness, security issues, architecture fit, "
                f"and CODING_STANDARDS compliance.\n\n{review_preview}"
            )
            review_result = await review.run(review_prompt)
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
