import asyncio
import argparse
import os
import logging
from typing import Any

from tenacity import retry, stop_after_attempt, wait_exponential, retry_if_exception_type
from pydantic_ai import UsageLimits

from openclaw.observability import configure_observability
from openclaw.registry import registry
from openclaw.writer import ArtifactWriter
from openclaw.checkpoint import CheckpointManager
from openclaw.models.core import PipelineState
from openclaw.telemetry import telemetry
from openclaw.gates import HumanInTheLoopGate
from openclaw.validators import CodeValidator
from openclaw.utils import format_artifacts
from openclaw.session_recorder import recorder
from openclaw.settings import settings

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
logger = logging.getLogger(__name__)

configure_observability()

DEFAULT_REQUIREMENT = "Build a message processing service that processes incoming message then and emits 'NotificationDetailsEvent' or 'NotificationStatus' events."
STEP_CHOICES = ["ba", "backend", "frontend", "test", "sre", "review", "database", "devops", "docs", "security", "all"]
DEFAULT_AGENT_TIMEOUT = 600.0


async def run_agent(
    semaphore: asyncio.Semaphore,
    agent_name: str,
    agent,
    prompt: str,
    deps: Any = None,
    timeout: float = DEFAULT_AGENT_TIMEOUT,
) -> Any:
    async with semaphore:
        @retry(
            stop=stop_after_attempt(3),
            wait=wait_exponential(multiplier=1, min=2, max=30),
            retry=retry_if_exception_type((TimeoutError, ConnectionError, OSError)),
            reraise=True,
        )
        async def _run_with_retry():
            coro = agent.run(prompt, deps=deps, usage_limits=UsageLimits(request_limit=500)) if deps is not None else agent.run(prompt, usage_limits=UsageLimits(request_limit=500))
            return await asyncio.wait_for(coro, timeout=timeout)

        return await telemetry.track(agent_name, _run_with_retry)


async def run_ba_stage(semaphore, state: PipelineState, raw_requirements: str, checkpoint_mgr) -> PipelineState:
    prompt = f"Process these requirements: {raw_requirements}"
    logger.info(f"BA Agent processing: {raw_requirements}")
    async with recorder.record_span(
        run_id=state.run_id, agent_name="ba", pipeline_stage="ba",
        prompt=prompt, context_summary=raw_requirements,
    ) as rec:
        ba_agent = registry.get("ba")
        ba_result = await run_agent(semaphore, "ba", ba_agent, prompt)
        state.user_stories = ba_result.output if hasattr(ba_result, "output") else None

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
    logger.info("Running CTO & UX Advisory...")
    story_context = "\n".join(f"- {us.id}: {us.title}\n  {us.gherkin}" for us in user_stories)

    cto_agent = registry.get("cto")
    ux_agent = registry.get("ux")

    from openclaw.agents.cto import OrgContext
    org_ctx = OrgContext(tech_stack=["Go", "Vue", "PostgreSQL", "Redis"],
                         compliance_tier="Standard", monthly_cloud_budget=1000.0)

    cto_prompt = f"Review these user stories and provide architectural advice:\n{story_context}"
    ux_prompt = f"Review these user stories and provide UX/UI advice:\n{story_context}"

    async def _run_cto():
        async with recorder.record_span(
            run_id=state.run_id, agent_name="cto", pipeline_stage="advisory",
            prompt=cto_prompt, context_summary=f"{len(user_stories)} stories",
        ) as rec:
            result = await run_agent(semaphore, "cto", cto_agent, cto_prompt, deps=org_ctx)
            rec.set_output(result)
            return result

    async def _run_ux():
        async with recorder.record_span(
            run_id=state.run_id, agent_name="ux", pipeline_stage="advisory",
            prompt=ux_prompt, context_summary=f"{len(user_stories)} stories",
        ) as rec:
            result = await run_agent(semaphore, "ux", ux_agent, ux_prompt)
            rec.set_output(result)
            return result

    advisory_results = await asyncio.gather(_run_cto(), _run_ux(), return_exceptions=True)

    state.advisory_results = {}
    state.cto_approved = True
    cto_blockers = []

    if not isinstance(advisory_results[0], BaseException):
        cto_data = advisory_results[0].output
        recs = cto_data.recommendations or []
        cto_text = "CTO Guidelines:\n" + "\n".join(recs) if recs else "CTO Guidelines: (none)"
        state.advisory_results["cto"] = cto_text
        state.cto_approved = cto_data.approved_to_proceed
        cto_blockers = cto_data.bottlenecks_identified or []
        logger.info(f"CTO recs={len(recs)}, blockers={len(cto_blockers)}, approved={state.cto_approved}")
    else:
        logger.warning(f"CTO agent failed: {advisory_results[0]}")

    if not isinstance(advisory_results[1], BaseException):
        ux_data = advisory_results[1].output
        recs = ux_data.recommendations or []
        ux_text = "UX Guidelines:\n" + "\n".join(recs) if recs else "UX Guidelines: (none)"
        state.advisory_results["ux"] = ux_text
        logger.info(f"UX recs={len(recs)}")
    else:
        logger.warning(f"UX agent failed: {advisory_results[1]}")
        state.advisory_results["ux"] = "UX Guidelines: (failed)"

    state.stage = "advisory"
    checkpoint_mgr.save("advisory", state)
    return state


async def run_implementation_stage(semaphore, user_stories, max_retries, cto_advice, ux_advice, raw_requirements, state: PipelineState | None = None) -> tuple[list[Any], str | None]:
    state_feedback = None
    all_artifacts = []

    for attempt in range(max_retries):
        logger.info(f"--- Implementation attempt {attempt + 1}/{max_retries} ---")
        artifacts: list[Any] = []

        from openclaw.agents.backend import ProjectState
        from openclaw.models.core import Artifact

        project_state = ProjectState(base_path="/app/default", environment="dev", team_owner="platform-engineering")

        async def _instrumented_test(sem, state, us):
            async with recorder.record_span(
                run_id=state.run_id, agent_name="test_eng", pipeline_stage="implementation",
                prompt=f"Write tests for gherkin: {us.gherkin}", story_id=us.id, story_gherkin=us.gherkin,
            ) as rec:
                res = await run_agent(sem, "test_eng", registry.get("test_eng"),
                    f"Write tests for gherkin: {us.gherkin}")
                rec.set_output(res)
                res.output.metadata["user_story_id"] = us.id
                return res.output

        async def run_tagged(sem, agent, prompt, story_id=None, deps=None):
            label = f"{story_id or 'global'}:{agent}"
            logger.info(f"▶ AGENT_START [{label}] — {prompt[:120]}")
            async with recorder.record_span(
                run_id=state.run_id, agent_name=agent, pipeline_stage="implementation",
                prompt=prompt, story_id=story_id or "",
            ) as rec:
                res = await run_agent(sem, agent, registry.get(agent), prompt, deps=deps)
                rec.set_output(res)
                res.output.metadata["user_story_id"] = story_id or "global"
                logger.info(f"✓ AGENT_END   [{label}]")
                return res.output

        per_story_tasks = []
        for us in user_stories:
            for agent, prompt_template, extra in [
                ("backend",
                 f"Implement backend for story {us.id}: {us.title}\n\nFULL GHERKIN:\n{us.gherkin}\n\nEVENTS:\n" +
                 "\n".join(f" - {e.name}: {e.description}" for e in (us.event_triggers or [])) +
                 f"\n\nCTO ADVICE:\n{cto_advice}",
                 f"story_id={us.id}, gherkin_len={len(us.gherkin)}, events={len(us.event_triggers or [])}"),
                ("frontend",
                 f"Implement frontend for story {us.id}: {us.title}\n\nFULL GHERKIN:\n{us.gherkin}\n\nCTO ADVICE:\n{cto_advice}\n\nUX GUIDELINES:\n{ux_advice}",
                 f"story_id={us.id}, gherkin_len={len(us.gherkin)}, ux_len={len(ux_advice)}"),
                ("database",
                 f"Generate database schema/migrations for story {us.id}: {us.title}\n\nFULL GHERKIN:\n{us.gherkin}\n\nEVENTS:\n" +
                 "\n".join(f" - {e.name}: {e.description}" for e in (us.event_triggers or [])),
                 f"story_id={us.id}, gherkin_len={len(us.gherkin)}"),
            ]:
                ctx_size = len(prompt_template)
                logger.info(f"CONTEXT [{agent}] → {extra} | prompt_size={ctx_size}")
                logger.info(f"CONTEXT_PREVIEW [{agent}]: {prompt_template[:300]}...")
                per_story_tasks.append(run_tagged(semaphore, agent, prompt_template,
                                                  story_id=us.id,
                                                  deps=project_state if agent == "backend" else None))

        devops_prompt = (
            f"Generate CI/CD pipelines and Docker Compose configurations for a project with these stories:\n" +
            "\n".join(f"- {us.id}: {us.title} — {us.gherkin[:200]}" for us in user_stories)
        )
        docs_prompt = (
            f"Generate API docs and README for: {raw_requirements}\n\n"
            f"Stories:\n" +
            "\n".join(f"- {us.id}: {us.title}\n  {us.gherkin[:200]}" for us in user_stories)
        )
        logger.info(f"CONTEXT [devops] → {len(user_stories)} stories | prompt_size={len(devops_prompt)}")
        logger.info(f"CONTEXT [docs] → {len(user_stories)} stories | prompt_size={len(docs_prompt)}")

        global_tasks = [
            run_tagged(semaphore, "devops", devops_prompt),
            run_tagged(semaphore, "docs", docs_prompt),
        ]

        per_story_results = await asyncio.gather(*per_story_tasks, return_exceptions=True)
        global_results = await asyncio.gather(*global_tasks, return_exceptions=True)

        for r in per_story_results + global_results:
            if isinstance(r, Artifact):
                artifacts.append(r)
            elif isinstance(r, Exception):
                logger.error(f"Implementation task raised: {r}")

        logger.info("Running Test agents per story...")
        test_tasks = []
        for us in user_stories:
            test_tasks.append(
                _instrumented_test(semaphore, state, us)
            )
        test_results = await asyncio.gather(*test_tasks, return_exceptions=True)
        for t, res in zip(test_tasks, test_results):
            if isinstance(res, BaseException):
                logger.error(f"Test agent failed: {res}")
                continue
            res.metadata["user_story_id"] = res.metadata.get("user_story_id", "?")
            artifacts.append(res)

        logger.info("Running SRE Agent...")
        async with recorder.record_span(
            run_id=state.run_id, agent_name="sre", pipeline_stage="implementation",
            prompt="Provision infrastructure and apply Helm charts for the services.",
        ) as rec:
            sre_res = await run_agent(semaphore, "sre", registry.get("sre"), "Provision infrastructure and apply Helm charts for the services.")
            rec.set_output(sre_res)
            sre_res.output.metadata["user_story_id"] = "infrastructure"
            sre_res.output.agent_name = "infrastructure"
            artifacts.append(sre_res.output)

        full_text = format_artifacts(artifacts, max_chars=80_000)

        logger.info("Running Code Validation...")
        if not await CodeValidator.run_all_async(artifacts):
            logger.warning("Code validation failed. Will retry.")
            if attempt < max_retries - 1:
                continue
            logger.error("Code validation failed after all retries.")
            return [], state_feedback

        logger.info("Running Security Audit...")
        async with recorder.record_span(
            run_id=state.run_id, agent_name="security", pipeline_stage="implementation",
            prompt=f"Audit the following code for vulnerabilities:\n{full_text}",
        ) as rec:
            sec_res = await run_agent(semaphore, "security", registry.get("security"),
                f"Audit the following code for vulnerabilities:\n{full_text}")
            rec.set_output(sec_res)
            sec_result = sec_res.output
            logger.info(f"Security: passed={sec_result.passed}, score={sec_result.score}")
            if not sec_result.passed:
                logger.warning("Security audit failed. Will retry.")
                if attempt < max_retries - 1:
                    continue
                logger.error("Security audit failed after all retries.")
                return [], state_feedback

        logger.info("Running Quality Gate...")
        async with recorder.record_span(
            run_id=state.run_id, agent_name="quality_gate", pipeline_stage="implementation",
            prompt=f"Perform quality gate check on these artifacts:",
        ) as rec:
            q_res = await run_agent(semaphore, "quality_gate", registry.get("quality_gate"),
                f"Perform quality gate check on these artifacts:\n{full_text}")
            rec.set_output(q_res)
            q_result = q_res.output
            logger.info(f"Quality Gate: passed={q_result.passed}, complexity={q_result.complexity_score}")
            if not q_result.passed:
                logger.warning("Quality Gate rejected. Retrying...")
                state_feedback = "\n".join(q_result.feedback)
                continue

        logger.info("Running Board of Review...")
        review_prompt = (
            f"Review the following generated artifacts:\n{full_text}\n"
            f"Ensure code is robust, secure, and meets all criteria."
        )
        if state_feedback:
            review_prompt += f"\n\nAddress previous feedback: {state_feedback}"

        async with recorder.record_span(
            run_id=state.run_id, agent_name="review", pipeline_stage="implementation",
            prompt=review_prompt,
        ) as rec:
            review_res = await run_agent(semaphore, "review", registry.get("review"), review_prompt)
            rec.set_output(review_res)
            result = review_res.output
            logger.info(f"Review: approved={result.approved}, risk={result.risk_level}, security_score={result.security_score}")
            if result.approved:
                all_artifacts = artifacts
                break
            else:
                logger.warning("Review rejected. Retrying...")
                state_feedback = "\n".join(result.feedback)

    return all_artifacts, state_feedback


async def write_artifacts(artifacts, project: str, auto_yes: bool = False, checkpoint_mgr=None):
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


async def main(
    project: str = "default",
    step: str = "all",
    resume: bool = False,
    auto_yes: bool = False,
    dry_run: bool = False,
    requirement: str | None = None,
):
    logger.info(f"--- OpenClaw Multi-Agent Ecosystem Pipeline (Project: {project}) ---")

    from openclaw.healthcheck import assert_startup_checks
    assert_startup_checks()

    from openclaw.agents.registration import register_all_agents
    register_all_agents()
    logger.info(f"Registered agents: {registry.list_agents()}")

    raw_requirements = requirement or os.getenv("REQUIREMENT") or DEFAULT_REQUIREMENT

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
        loaded_state = checkpoint_mgr.load("ba")
        if loaded_state is None:
            logger.warning("BA checkpoint exists but failed to load. Re-running BA stage.")
            state = await run_ba_stage(semaphore, state, raw_requirements, checkpoint_mgr)
            if not state.user_stories:
                return
        else:
            state = loaded_state
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
        loaded_state = checkpoint_mgr.load("advisory")
        if loaded_state is None:
            logger.warning("Advisory checkpoint exists but failed to load. Re-running.")
            state = await run_advisory_stage(semaphore, user_stories, checkpoint_mgr, state)
        else:
            state = loaded_state
            logger.info("Skipping Advisory phase (checkpoint restored)")
    else:
        state = await run_advisory_stage(semaphore, user_stories, checkpoint_mgr, state)

    cto_advice = state.advisory_results.get("cto", "")
    ux_advice = state.advisory_results.get("ux", "")
    max_retries = settings.max_retries if step == "all" else 1

    from openclaw.cto_gate import apply as cto_gate
    if not await cto_gate(state, project=project):
        return

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

    should_run_implementation = True
    if dry_run:
        should_run_implementation = False
    elif resume and checkpoint_mgr.stage_exists("implementation"):
        loaded_state = checkpoint_mgr.load("implementation")
        if loaded_state is not None:
            state = loaded_state
            logger.info("Skipping Implementation phase (checkpoint restored)")
            should_run_implementation = False
        else:
            logger.warning("Implementation checkpoint exists but failed to load. Re-running.")

    if should_run_implementation:
        state.feedback = None
        state.artifacts = []
        state.artifacts, state.feedback = await run_implementation_stage(
            semaphore, user_stories, max_retries, cto_advice, ux_advice, raw_requirements, state=state
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

    asyncio.run(main(args.project, args.step, args.resume, args.yes, args.dry_run, requirement=args.requirement))
