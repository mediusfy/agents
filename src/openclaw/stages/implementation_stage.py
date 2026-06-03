import asyncio
import logging

from openclaw.models.core import Artifact, FailureReport, PipelineState
from openclaw.pipeline.config import PipelineConfig
from openclaw.registry import registry
from openclaw.session_recorder import recorder
from openclaw.settings import settings
from openclaw.stages.base import StageRunner

logger = logging.getLogger(__name__)


class ImplementationStage(StageRunner):
    async def run(self, state: PipelineState, config: PipelineConfig) -> PipelineState:
        logger.info("--- Running Implementation Stage ---")

        if config.dry_run:
            logger.info("DRY RUN: Generating mock implementation artifacts.")
            state.artifacts = [
                Artifact(
                    agent_name="backend",
                    files={"cmd/server/main.go": "package main\nfunc main() {}\n"},
                    metadata={"user_story_id": "US-001", "language": "go"},
                ),
                Artifact(
                    agent_name="frontend",
                    files={"src/App.vue": "<template><div>Hello</div></template>\n"},
                    metadata={"user_story_id": "US-001", "language": "vue"},
                ),
                Artifact(
                    agent_name="test",
                    files={"tests/payment.spec.ts": "test('payment', () => {});\n"},
                    metadata={"user_story_id": "US-001"},
                ),
            ]
            state.stage = "implementation"
            return state

        semaphore = asyncio.Semaphore(settings.max_concurrent_llm_calls)
        user_stories = state.user_stories or []
        cto_advice = state.advisory_results.get("cto", "")
        ux_advice = state.advisory_results.get("ux", "")
        raw_requirements = config.requirement or ""

        # Using the Workspace adapter if needed, but since it's injected we can import it
        from openclaw.adapters.workspace import WorkspaceContext

        workspace = WorkspaceContext()
        repo_context = workspace.get_repo_context()

        is_retry = getattr(state, "failure_report", None) is not None
        artifacts = list(state.artifacts) if is_retry and state.artifacts else []

        from openclaw.agents.backend import ProjectState

        project_state = ProjectState(base_path="/app/default", environment="dev", team_owner="platform-engineering")

        async def _instrumented_test(sem, us):
            async with recorder.record_span(
                run_id=state.run_id,
                agent_name="test_eng",
                pipeline_stage="implementation",
                prompt=f"Write tests for gherkin: {us.gherkin}",
                story_id=us.id,
                story_gherkin=us.gherkin,
            ) as rec:
                res = await self.provider.run_agent(
                    sem, "test_eng", registry.get("test_eng"), f"Write tests for gherkin: {us.gherkin}"
                )
                rec.set_output(res)
                res.output.metadata["user_story_id"] = us.id
                return res.output

        async def run_tagged(sem, agent, prompt, story_id=None, deps=None):
            label = f"{story_id or 'global'}:{agent}"
            logger.info(f"▶ AGENT_START [{label}]")
            async with recorder.record_span(
                run_id=state.run_id,
                agent_name=agent,
                pipeline_stage="implementation",
                prompt=prompt,
                story_id=story_id or "",
            ) as rec:
                res = await self.provider.run_agent(sem, agent, registry.get(agent), prompt, deps=deps)
                rec.set_output(res)
                res.output.metadata["user_story_id"] = story_id or "global"
                logger.info(f"✓ AGENT_END   [{label}]")
                return res.output

        async def run_backend_phases(sem, us, repo_ctx, cto_adv, proj_state):
            if is_retry:
                patch_prompt = (
                    f"{repo_ctx}\n\nCTO ADVICE:\n{cto_adv}\n\nFULL GHERKIN:\n{us.gherkin}\n\n"
                    "PREVIOUS FAILURE DETECTED:\n"
                    f"Source: {state.failure_report.source}\n"
                    f"Error Type: {state.failure_report.error_type}\n"
                    f"Trace/Feedback:\n{state.failure_report.trace}\n\n"
                    "TASK: Analyze the failure telemetry and generate a hyper-specific patch to fix the issue. "
                    "Only output the corrected files instead of rewriting the entire backend from scratch."
                )
                res = await run_tagged(sem, "backend", patch_prompt, story_id=us.id, deps=proj_state)
                return [res]

            backend_arts = []

            p1_prompt = (
                f"{repo_ctx}\n\nCTO ADVICE:\n{cto_adv}\n\nFULL GHERKIN:\n{us.gherkin}\n\n"
                "TASK: Phase 1. Given the user story, generate ONLY the domain structs "
                "and interface definitions. Output: domain/types.go"
            )
            p1_res = await run_tagged(sem, "backend", p1_prompt, story_id=us.id, deps=proj_state)
            backend_arts.append(p1_res)
            p1_files = (
                "\n".join(f"--- {k} ---\n{v}" for k, v in p1_res.files.items()) if hasattr(p1_res, "files") else ""
            )

            p2_prompt = (
                f"Phase 2. Given these interfaces:\n{p1_files}\n\n"
                "TASK: Implement the Postgres database adapters. Output: adapters/postgres_repo.go"
            )
            p2_res = await run_tagged(sem, "backend", p2_prompt, story_id=us.id, deps=proj_state)
            backend_arts.append(p2_res)
            p2_files = (
                "\n".join(f"--- {k} ---\n{v}" for k, v in p2_res.files.items()) if hasattr(p2_res, "files") else ""
            )

            p3_prompt = (
                f"Phase 3. Given the domain structs:\n{p1_files}\n\n"
                "TASK: Write the Pub/Sub event handlers and definitions. Output: ports/events.go"
            )
            p3_res = await run_tagged(sem, "backend", p3_prompt, story_id=us.id, deps=proj_state)
            backend_arts.append(p3_res)
            p3_files = (
                "\n".join(f"--- {k} ---\n{v}" for k, v in p3_res.files.items()) if hasattr(p3_res, "files") else ""
            )

            p4_prompt = (
                f"Phase 4. Given the interfaces:\n{p1_files}\n\nDB Adapters:\n{p2_files}\n\nEvents:\n{p3_files}\n\n"
                "TASK: Implement the core business logic service wiring them together. Output: domain/service.go"
            )
            p4_res = await run_tagged(sem, "backend", p4_prompt, story_id=us.id, deps=proj_state)
            backend_arts.append(p4_res)

            return backend_arts

        per_story_tasks = []
        for us in user_stories:
            per_story_tasks.append(run_backend_phases(semaphore, us, repo_context, cto_advice, project_state))

            if not is_retry:
                fe_prompt = (
                    f"{repo_context}\n\nCTO ADVICE:\n{cto_advice}\n\n"
                    f"UX GUIDELINES:\n{ux_advice}\n\n"
                    f"FULL GHERKIN:\n{us.gherkin}\n\n"
                    f"TASK:\nImplement frontend for story {us.id}: {us.title}"
                )
                per_story_tasks.append(run_tagged(semaphore, "frontend", fe_prompt, story_id=us.id))

                db_prompt = (
                    f"FULL GHERKIN:\n{us.gherkin}\n\nEVENTS:\n"
                    + "\n".join(f" - {e.name}: {e.description}" for e in (us.event_triggers or []))
                    + f"\n\nTASK:\nGenerate database schema/migrations for story {us.id}: {us.title}"
                )
                per_story_tasks.append(run_tagged(semaphore, "database", db_prompt, story_id=us.id))

        if not is_retry:
            devops_prompt = "Generate CI/CD pipelines and Docker Compose for these stories:\n" + "\n".join(
                f"- {us.id}: {us.title}" for us in user_stories
            )
            docs_prompt = f"Generate API docs and README for: {raw_requirements}"

            global_tasks = [
                run_tagged(semaphore, "devops", devops_prompt),
                run_tagged(semaphore, "docs", docs_prompt),
            ]
        else:
            global_tasks = []

        per_story_results = await asyncio.gather(*per_story_tasks, return_exceptions=True)
        global_results = await asyncio.gather(*global_tasks, return_exceptions=True)

        for r in per_story_results + global_results:
            if isinstance(r, list):
                for sub_r in r:
                    if isinstance(sub_r, Artifact):
                        if is_retry:
                            # Merge files into existing artifact if it exists
                            merged = False
                            for art in artifacts:
                                if art.agent_name == sub_r.agent_name and art.metadata.get(
                                    "user_story_id"
                                ) == sub_r.metadata.get("user_story_id"):
                                    art.files.update(sub_r.files)
                                    merged = True
                                    break
                            if not merged:
                                artifacts.append(sub_r)
                        else:
                            artifacts.append(sub_r)
            elif isinstance(r, Artifact):
                if is_retry:
                    merged = False
                    for art in artifacts:
                        if art.agent_name == r.agent_name and art.metadata.get("user_story_id") == r.metadata.get(
                            "user_story_id"
                        ):
                            art.files.update(r.files)
                            merged = True
                            break
                    if not merged:
                        artifacts.append(r)
                else:
                    artifacts.append(r)
            elif isinstance(r, Exception):
                logger.error(f"Implementation task raised: {r}")

        logger.info("Running Test agents per story...")
        test_tasks = []
        for us in user_stories:
            test_tasks.append(_instrumented_test(semaphore, us))

        test_results = await asyncio.gather(*test_tasks, return_exceptions=True)

        test_failure_trace = None
        from openclaw.tools.test_tools import execute_test_suite

        for _t, res in zip(test_tasks, test_results, strict=False):
            if isinstance(res, BaseException):
                logger.error(f"Test agent failed: {res}")
                continue
            res.metadata["user_story_id"] = res.metadata.get("user_story_id", "?")

            # Remove old test artifact for this story before appending the new one
            artifacts = [
                a
                for a in artifacts
                if not (a.agent_name == "test_eng" and a.metadata.get("user_story_id") == res.metadata["user_story_id"])
            ]
            artifacts.append(res)

            target_source_code = ""
            target_code_file = "service.go"
            for a in artifacts:
                # Ensure we test against backend artifact specifically to prevent flaky file resolution
                if (
                    a.agent_name == "backend"
                    and a.metadata.get("user_story_id") == res.metadata["user_story_id"]
                    and a.files
                ):
                    for fname, fcontent in a.files.items():
                        if fname.endswith(".go") or fname.endswith(".vue") or fname.endswith(".tsx"):
                            target_code_file = fname
                            target_source_code = fcontent
                            break
                    if target_source_code:
                        break

            if res.files and target_source_code:
                test_file_name = next(iter(res.files.keys()))
                test_source_code = res.files[test_file_name]
                trace = await execute_test_suite(test_file_name, test_source_code, target_code_file, target_source_code)
                if trace.startswith("FAILED"):
                    test_failure_trace = trace
                    break

        if test_failure_trace:
            logger.warning("Test suite failed. Sending feedback back to state.")
            state.feedback = (
                f"The test suite failed with the following trace:\n\n{test_failure_trace}\n\n"
                "Rewrite the implementation to resolve these errors."
            )
            state.failure_report = FailureReport(
                source="test_suite",
                error_type="test_failure",
                trace=test_failure_trace,
            )
            state.approved = False
        else:
            state.feedback = None
            state.failure_report = None
            # Explicitly clear approved status; handled by downstream gates
            state.approved = False

        state.artifacts = artifacts
        state.stage = "implementation"
        return state
