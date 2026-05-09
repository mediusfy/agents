import asyncio
import argparse
import os
from src.agents.ba import ba_agent
from src.agents.backend import backend_agent
from src.agents.frontend import frontend_agent
from src.agents.sre import sre_agent
from src.agents.test_eng import test_agent
from src.agents.review import review_agent
from src.agents.quality_gate import quality_gate_agent
from src.agents.cto import cto_agent
from src.agents.ux import ux_agent
from src.writer import ArtifactWriter
from src.config import AgentSettings

from typing import List, Any

def summarize_artifacts(artifacts: List[Any], max_chars: int = 1500) -> str:
    summary = []
    for art in artifacts:
        if isinstance(art, Exception):
            summary.append(f"Error: {art}")
            continue
        if hasattr(art, 'agent_name'):
            story_id = art.metadata.get('user_story_id', 'N/A')
            summary.append(f"Agent: {art.agent_name}, Story: {story_id}\\nFiles:")
            for filepath, content in art.files.items():
                content_preview = content[:max_chars]
                if len(content) > max_chars:
                    content_preview += f"\\n... [truncated, {len(content) - max_chars} more chars]"
                summary.append(f"  - {filepath}:\\n```\\n{content_preview}\\n```")
    return "\\n".join(summary)

DEFAULT_REQUIREMENT = "Build a payment processing service that handles incoming payments and emits 'PaymentSucceeded' or 'PaymentFailed' events."

async def main(step: str = "all"):
    print("--- OpenClaw Multi-Agent Ecosystem Pipeline ---")

    raw_requirements = os.getenv("REQUIREMENT", DEFAULT_REQUIREMENT)
    print(f"\\n[1] User Request: {raw_requirements}")
    
    print("\\n[2] Executing BA Agent...")
    try:
        ba_result = await ba_agent.run(f"Process these requirements: {raw_requirements}")
        user_stories = ba_result.data
    except Exception as e:
        print(f"BA Agent failed: {e}")
        return

    print(f"BA output {len(user_stories)} user stories.")
    if not user_stories:
        print("No user stories generated. Exiting.")
        return
        
    for us in user_stories:
        print(f"  - {us.id}: {us.title}")

    if step == "ba":
        print("\n[✓] BA step complete. Exiting (--step ba).")
        return

    print("\n[2.5] Executing CTO & UX Advisory...")
    story_context = "\n".join([f"- {us.id}: {us.title}\n  {us.gherkin}" for us in user_stories])
    
    cto_task = cto_agent.run(f"Review these user stories and provide architectural advice and bottleneck warnings:\n{story_context}")
    ux_task = ux_agent.run(f"Review these user stories and provide UX/UI advice:\n{story_context}")
    
    advisory_results = await asyncio.gather(cto_task, ux_task, return_exceptions=True)
    
    cto_advice = ""
    ux_advice = ""
    
    if not isinstance(advisory_results[0], Exception):
        cto_advice = "\nCTO Guidelines:\n" + "\n".join(advisory_results[0].data.recommendations)
    else:
        print(f"CTO Agent failed: {advisory_results[0]}")
        
    if not isinstance(advisory_results[1], Exception):
        ux_advice = "\nUX Guidelines:\n" + "\n".join(advisory_results[1].data.recommendations)
    else:
        print(f"UX Agent failed: {advisory_results[1]}")

    MAX_RETRIES = AgentSettings.MAX_RETRIES if step == "all" else 1
    review_feedback = None

    for attempt in range(MAX_RETRIES):
        print(f"\\n--- Attempt {attempt + 1} of {MAX_RETRIES} ---")
        artifacts = []

        print("\\n[3] Executing Backend & Frontend Agents in parallel...")
        backend_tasks = [backend_agent.run(f"Implement backend for story {us.id}: {us.title}\n{cto_advice}") for us in user_stories]
        frontend_tasks = [frontend_agent.run(f"Implement frontend for story {us.id}: {us.title}\n{cto_advice}\n{ux_advice}") for us in user_stories]
        
        results = await asyncio.gather(*backend_tasks, *frontend_tasks, return_exceptions=True)
        
        for i, res in enumerate(results):
            if isinstance(res, Exception):
                print(f"Agent failed: {res}")
                continue
            story_idx = i % len(user_stories)
            res.data.metadata["user_story_id"] = user_stories[story_idx].id
            artifacts.append(res.data)

        if step in ("backend", "frontend"):
            print(f"\\n[✓] {step} step complete. Exiting (--step {step}).")
            return

        print("\\n[4] Executing Test Agent in parallel...")
        test_tasks = [test_agent.run(f"Write tests for gherkin: {us.gherkin}") for us in user_stories]
        test_results = await asyncio.gather(*test_tasks, return_exceptions=True)
        for i, res in enumerate(test_results):
            if isinstance(res, Exception):
                print(f"Test Agent failed: {res}")
                continue
            res.data.metadata["user_story_id"] = user_stories[i].id
            artifacts.append(res.data)

        if step == "test":
            print("\\n[✓] Test step complete. Exiting (--step test).")
            return

        print("\\n[5] Executing SRE Agent...")
        try:
            sre_res = await sre_agent.run("Provision necessary infrastructure for the new services and apply helm charts.")
            sre_res.data.metadata["user_story_id"] = "infrastructure"
            sre_res.data.agent_name = "infrastructure"
            artifacts.append(sre_res.data)
        except Exception as e:
            print(f"SRE Agent failed: {e}")

        if step == "sre":
            print("\\n[✓] SRE step complete. Exiting (--step sre).")
            return

        print("\n[5.5] Executing Quality Gate Check...")
        summary = summarize_artifacts(artifacts)
        quality_prompt = f"Perform a quality gate check on the following artifacts:\n{summary}\n"
        
        try:
            quality_res = await quality_gate_agent.run(quality_prompt)
            q_result = quality_res.data
        except Exception as e:
            print(f"Quality Gate Agent failed: {e}")
            break
            
        print("\n--- Quality Gate Result ---")
        print(f"Passed: {q_result.passed}")
        print(f"Complexity Score: {q_result.complexity_score}")
        print(f"Feedback: {q_result.feedback}")
        
        if not q_result.passed:
            print("\n[!] Quality Gate rejected artifacts due to over-engineering. Retrying...")
            review_feedback = q_result.feedback
            continue

        print("\\n[6] Executing Board of Review...")
        review_prompt = f"Review the following generated artifacts for the project:\\n{summary}\\n\\nEnsure the generated code is robust and meets all criteria."
        
        if review_feedback:
            review_prompt += f"\\n\\nPlease ensure you address the previous feedback: {review_feedback}"

        try:
            review_res = await review_agent.run(review_prompt)
            result = review_res.data
        except Exception as e:
            print(f"Review Agent failed: {e}")
            break
        
        print("\\n--- Final Review Result ---")
        print(f"Approved: {result.approved}")
        print(f"Risk Level: {result.risk_level.value}")
        print(f"Security Score: {result.security_score}")
        print(f"Feedback: {result.feedback}")

        if result.approved:
            print(f"\\n[7] Writing approved artifacts to {AgentSettings.OUTPUT_DIR}...")
            writer = ArtifactWriter(AgentSettings.OUTPUT_DIR)
            for art in artifacts:
                writer.write(art)
            print("Done!")
            break
        else:
            print("\\n[!] Review rejected. Storing feedback and retrying if attempts remain.")
            review_feedback = result.feedback

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="OpenClaw Multi-Agent Pipeline")
    parser.add_argument("--step", choices=["ba", "backend", "frontend", "test", "sre", "review", "all"],
                        default="all", help="Run a specific pipeline step")
    parser.add_argument("--requirement", type=str, default=None,
                        help="Custom requirement text (default: sample payment service)")
    args = parser.parse_args()

    if args.requirement:
        os.environ["REQUIREMENT"] = args.requirement

    asyncio.run(main(args.step))
