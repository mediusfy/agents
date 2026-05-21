import asyncio
import argparse
import os
import logging
from typing import Any

import logfire

from openclaw.registry import registry
from openclaw.writer import ArtifactWriter
from openclaw.checkpoint import CheckpointManager
from openclaw.models.core import PipelineState
from openclaw.telemetry import telemetry
from openclaw.gates import HumanInTheLoopGate
from openclaw.validators import CodeValidator
from openclaw.utils import format_artifacts

logfire.configure()
logfire.instrument_pydantic()
logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
logger = logging.getLogger(__name__)

from openclaw.settings import settings

DEFAULT_REQUIREMENT = "Build a payment processing service that handles incoming payments and emits 'PaymentSucceeded' or 'PaymentFailed' events."

STEP_CHOICES = ["ba", "backend", "frontend", "test", "sre", "review",
                "database", "devops", "docs", "security", "all"]


async def run_agent(semaphore: asyncio.Semaphore, agent_name: str, agent, prompt: str, deps: Any = None) -> Any:
    async with semaphore:
        if deps is not None:
            return await telemetry.track(agent_name, agent.run, prompt, deps=deps)
        return await telemetry.track(agent_name, agent.run, prompt)


async def run_ba_stage(semaphore, state: PipelineState, raw_requirements: str, checkpoint_mgr) -> PipelineState:
    """Run the Business Analyst stage."""
    logger.info(f"BA Agent processing: {raw_requirements}")
    ba_agent = registry.get("ba")
    ba_result = await run_agent(semaphore, "ba", ba_agent, f"Process these requirements: {raw_requirements}")
    state.user_stories = ba_result.data

    if not state.user_stories:
        logger.warning("BA returned no user stories. Exiting.")
        return state

    logger.info(f"BA generated {len(state.user_stories)} stories:")
    for us in state.user_stories:
        logger.info(f"  [{us.id}] {us.title}")

    state.stage = "ba"
    checkpoint_mgr.save("ba", state)
    return state


async def run_advisory_stage(semaphore, user_stories, checkpoint_mgr, state: PipelineState) -> PipelineState:
    """Run the CTO and UX advisory stage."""
    logger.info("Running CTO & UX Advisory...")
    story_context = "\n".join(
        f"- {us.id}: {us.title}\n  {us.gherkin}" for us in user_stories
    )

    cto_agent = registry.get("cto")
    ux_agent = registry.get("ux")

    from openclaw.agents.cto import OrgContext
    org_ctx = OrgContext(tech_stack=["Go", "Vue", "PostgreSQL", "Redis"], compliance_tier="Standard", monthly_cloud_budget=1000.0)

    cto_task = run_agent(semaphore, "cto", cto_agent,
                         f"Review these user stories and provide architectural advice:\n{story_context}", deps=org_ctx)
    ux_task = run_agent(semaphore, "ux", ux_agent,
                        f"Review these user stories and provide UX/UI advice:\n{story_context}")

    advisory_results = await asyncio.gather(cto_task, ux_task, return_exceptions=True)

    state.advisory_results = {}
    if not isinstance(advisory_results[0], Exception):
        cto_data = advisory_results[0].data
        recs = cto_data.recommendations
        state.advisory_results["cto"] = "CTO Guidelines:\n" + "\n".join(recs) if recs else ""
    else:
        logger.warning(f"CTO agent failed: {advisory_results[0]}")

    if not isinstance(advisory_results[1], Exception):
        ux_data = advisory_results[1].data
        recs = ux_data.recommendations
        state.advisory_results["ux"] = "UX Guidelines:\n" + "\n".join(recs) if recs else ""
    else:
        logger.warning(f"UX agent failed: {advisory_results[1]}")

    state.stage = "advisory"
    checkpoint_mgr.save("advisory", state)
    return state


async def run_implementation_stage(semaphore, user_stories, max_retries, cto_advice, ux_advice, raw_requirements) -> (
    tuple[list[Any], str | None]
):
    """Run the implementation loops (backend, frontend, database, devops, docs, test, SRE)."""
    state_feedback = None
    all_artifacts = []

    for attempt in range(max_retries):
        logger.info(f"--- Implementation attempt {attempt + 1}/{max_retries} ---")
        artifacts: list[Any] = []

        logger.info("Running Backend, Frontend, Database agents per story...")
        impl_tasks = []

        from openclaw.agents.backend import ProjectState
        project_state = ProjectState(base_path="/app/default", environment="dev", team_owner="platform-engineering")

        for us in user_stories:
            impl_tasks.append(run_agent(semaphore, "backend", registry.get("backend"),
                f"Implement backend for story {us.id}: {us.title}\n{cto_advice}", deps=project_state))
            impl_tasks.append(run_agent(semaphore, "frontend", registry.get("frontend"),
                f"Implement frontend for story {us.id}: {us.title}\n{cto_advice}\n{ux_advice}"))
            impl_tasks.append(run_agent(semaphore, "database", registry.get("database"),
                f"Generate database schema/migrations for story {us.id}: {us.title}"))

        impl_tasks.append(run_agent(semaphore, "devops", registry.get("devops"),
            "Generate CI/CD pipelines and Docker Compose configurations"))
        impl_tasks.append(run_agent(semaphore, "docs", registry.get("docs"),
            f"Generate API docs and README for: {raw_requirements}"))

        impl_results = await asyncio.gather(*impl_tasks, return_exceptions=True)

        story_count = len(user_stories)
        per_story_count = 3
        for i, res in enumerate(impl_results):
            if isinstance(res, Exception):
                logger.error(f"Implementation agent failed at index {i}: {res}")
                continue
            if i < story_count * per_story_count:
                story_idx = i // per_story_count
                res.data.metadata["user_story_id"] = user_stories[story_idx].id
            else:
                res.data.metadata["user_story_id"] = "global"
            artifacts.append(res.data)

        logger.info("Running Test agents per story...")
        test_tasks = [
            run_agent(semaphore, "test", registry.get("test_eng"),
                      f"Write tests for gherkin: {us.gherkin}")
            for us in user_stories
        ]
        test_results = await asyncio.gather(*test_tasks, return_exceptions=True)
        for i, res in enumerate(test_results):
            if isinstance(res, Exception):
                logger.error(f"Test agent failed: {res}")
                continue
            res.data.metadata["user_story_id"] = user_stories[i].id
            artifacts.append(res.data)

        logger.info("Running SRE Agent...")
        try:
            sre_res = await run_agent(semaphore, "sre", registry.get("sre"),
                "Provision infrastructure and apply Helm charts for the services.")
            sre_res.data.metadata["user_story_id"] = "infrastructure"
            sre_res.data.agent_name = "infrastructure"
            artifacts.append(sre_res.data)
        except Exception as e:
            logger.error(f"SRE agent failed: {e}")

        full_text = format_artifacts(artifacts, max_chars=80_000)

        logger.info("Running Code Validation...")
        if not await CodeValidator.run_all_async(artifacts):
            logger.warning("Code validation failed. Will retry.")
            if attempt < max_retries - 1:
                continue
            logger.error("Code validation failed after all retries.")
            return [], state_feedback

        logger.info("Running Security Audit...")
        try:
            sec_res = await run_agent(semaphore, "security", registry.get("security"),
                f"Audit the following code for vulnerabilities:\n{full_text}")
            sec_result = sec_res.data
            logger.info(f"Security: passed={sec_result.passed}, score={sec_result.score}")
            if not sec_result.passed:
                logger.warning("Security audit failed. Will retry.")
                if attempt < max_retries - 1:
                    continue
                logger.error("Security audit failed after all retries.")
                return [], state_feedback
        except Exception as e:
            logger.error(f"Security agent failed: {e}")
            if attempt < max_retries - 1:
                continue
            return [], state_feedback

        logger.info("Running Quality Gate...")
        try:
            q_res = await run_agent(semaphore, "quality_gate", registry.get("quality_gate"),
                f"Perform quality gate check on these artifacts:\n{full_text}")
            q_result = q_res.data
            logger.info(f"Quality Gate: passed={q_result.passed}, complexity={q_result.complexity_score}")
            if not q_result.passed:
                logger.warning("Quality Gate rejected. Retrying...")
                state_feedback = "\n".join(q_result.feedback)
                continue
        except Exception as e:
            logger.error(f"Quality Gate failed: {e}")
            break

        logger.info("Running Board of Review...")
        review_prompt = (
            f"Review the following generated artifacts:\n{full_text}\n"
            f"Ensure code is robust, secure, and meets all criteria."
        )
        if state_feedback:
            review_prompt += f"\n\nAddress previous feedback: {state_feedback}"

        try:
            review_res = await run_agent(semaphore, "review", registry.get("review"), review_prompt)
            result = review_res.data
            logger.info(f"Review: approved={result.approved}, risk={result.risk_level}, security_score={result.security_score}")
        except Exception as e:
            logger.error(f"Review agent failed: {e}")
            break

        if result.approved:
            all_artifacts = artifacts
            break
        else:
            logger.warning("Review rejected. Retrying...")
            state_feedback = "\n".join(result.feedback)

    return all_artifacts, state_feedback


async def write_artifacts(artifacts, project: str, auto_yes: bool = False, checkpoint_mgr=None):
    """Write artifacts to disk after optional human-in-the-loop gate."""
    if not artifacts:
        logger.warning("No artifacts to write.")
        return

    proceed = HumanInTheLoopGate.prompt_proceed(artifacts, auto_yes)
    if proceed:
        project_output_dir = os.path.join(str(settings.output_dir), project)
        logger.info(f"Writing {len(artifacts)} artifacts to {project_output_dir}...")
        writer = ArtifactWriter(project_output_dir)
        for art in artifacts:
            writer.write(art)
        if checkpoint_mgr:
            checkpoint_mgr.clear()
        logger.info("Pipeline complete. Artifacts written to disk.")
    else:
        logger.info("User aborted write. Artifacts preserved in checkpoint.")


async def main(project: str = "default", step: str = "all", resume: bool = False, auto_yes: bool = False, dry_run: bool = False):
    logger.info(f"--- OpenClaw Multi-Agent Ecosystem Pipeline (Project: {project}) ---")

    from openclaw.healthcheck import assert_startup_checks
    assert_startup_checks()

    from openclaw.agents.registration import register_pipeline_agents
    register_pipeline_agents()
    logger.info(f"Registered agents: {registry.list_agents()}")

    raw_requirements = os.getenv("REQUIREMENT", DEFAULT_REQUIREMENT)

    if resume:
        checkpoint_mgr = CheckpointManager(project)
        run_id = checkpoint_mgr.find_latest_run_id()
        if run_id:
            checkpoint_mgr = CheckpointManager(project, run_id=run_id)
            logger.info(f"Resuming run: {run_id}")
        else:
            logger.warning("No checkpoint found to resume. Starting fresh.")
            checkpoint_mgr = CheckpointManager(project)
    else:
        checkpoint_mgr = CheckpointManager(project)
        checkpoint_mgr.clear()

    semaphore = asyncio.Semaphore(settings.max_concurrent_llm_calls)
    state = PipelineState(run_id=checkpoint_mgr.run_id, stage="init")

    if dry_run:
        logger.info("DRY RUN: Using mock data.")
        from openclaw.models.core import UserStory, EventTrigger
        state.user_stories = [
            UserStory(id="US-001", title="Process Payment",
                      gherkin="Given a valid payment request\nWhen the system processes it\nThen it emits PaymentSucceeded",
                      event_triggers=[EventTrigger(id="evt-1", name="PaymentSucceeded", description="Payment processed")]),
        ]
    elif resume and checkpoint_mgr.stage_exists("ba"):
        state = checkpoint_mgr.load("ba")
        logger.info("Skipping BA Agent (checkpoint restored)")
    else:
        state = await run_ba_stage(semaphore, state, raw_requirements, checkpoint_mgr)
        if not state.user_stories:
            return

    if step == "ba":
        logger.info("--step ba complete.")
        return

    user_stories = state.user_stories

    if dry_run:
        logger.info("DRY RUN: Skipping Advisory phase.")
    elif resume and checkpoint_mgr.stage_exists("advisory"):
        state = checkpoint_mgr.load("advisory")
        logger.info("Skipping Advisory phase (checkpoint restored)")
    else:
        state = await run_advisory_stage(semaphore, user_stories, checkpoint_mgr, state)

    cto_advice = state.advisory_results.get("cto", "")
    ux_advice = state.advisory_results.get("ux", "")
    max_retries = settings.max_retries if step == "all" else 1

    if dry_run:
        logger.info("DRY RUN: Generating mock artifacts.")
        from openclaw.models.core import Artifact
        state.artifacts = [
            Artifact(agent_name="backend", files={"cmd/server/main.go": "package main\nfunc main() {}\n"},
                     metadata={"user_story_id": "US-001", "language": "go"}),
            Artifact(agent_name="frontend", files={"src/App.vue": "<template><div>Hello</div></template>\n"},
                     metadata={"user_story_id": "US-001", "language": "vue"}),
            Artifact(agent_name="database", files={"migrations/001_init.sql": "CREATE TABLE payments (id UUID PRIMARY KEY);\n"},
                     metadata={"user_story_id": "US-001"}),
            Artifact(agent_name="infrastructure", files={"terraform/main.tf": "# mock\nresource \"null_resource\" \"x\" {}\n"},
                     metadata={"user_story_id": "infrastructure"}),
            Artifact(agent_name="test", files={"tests/payment.spec.ts": "test('payment', () => {});\n"},
                     metadata={"user_story_id": "US-001"}),
        ]
        state.stage = "implementation"
    elif resume and checkpoint_mgr.stage_exists("implementation"):
        state = checkpoint_mgr.load("implementation")
        logger.info("Skipping Implementation phase (checkpoint restored)")
    else:
        state.feedback = None
        state.artifacts = []
        state.artifacts, state.feedback = await run_implementation_stage(
            semaphore, user_stories, max_retries, cto_advice, ux_advice, raw_requirements
        )

        if state.artifacts:
            state.stage = "implementation"
            checkpoint_mgr.save("implementation", state)

    if not state.artifacts:
        logger.error("Pipeline completed without approved artifacts.")
        return

    if step in STEP_CHOICES and step != "all":
        logger.info(f"--step {step} complete.")
        return

    if dry_run:
        logger.info("DRY RUN: Writing to dry-run output.")
        project_output_dir = os.path.join(str(settings.output_dir), project)
        writer = ArtifactWriter(project_output_dir)
        for art in state.artifacts:
            writer.write(art)
        logger.info(f"DRY RUN: Wrote {len(state.artifacts)} artifacts to {project_output_dir}")
        return

    await write_artifacts(state.artifacts, project, auto_yes, checkpoint_mgr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="OpenClaw Multi-Agent Pipeline")
    parser.add_argument("--step", choices=STEP_CHOICES, default="all",
                        help="Run a specific pipeline step")
    parser.add_argument("--project", type=str, default="default",
                        help="Project name to isolate outputs and checkpoints")
    parser.add_argument("--requirement", type=str, default=None,
                        help="Custom requirement text")
    parser.add_argument("--resume", action="store_true",
                        help="Resume from last checkpoint")
    parser.add_argument("--yes", action="store_true",
                        help="Skip human-in-the-loop confirmation")
    parser.add_argument("--dry-run", action="store_true",
                        help="Run pipeline with mock data (no LLM calls)")
    args = parser.parse_args()

    if args.requirement:
        os.environ["REQUIREMENT"] = args.requirement

    asyncio.run(main(args.project, args.step, args.resume, args.yes, args.dry_run))
