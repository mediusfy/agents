import logging
import asyncio
import logfire
import os
from openclaw.task_queue import task_queue
from openclaw.registry import registry
from openclaw.memory import long_term_memory
from openclaw.tools.validators import lint_python_file
from openclaw.critical_actions import CRITICAL_CAPABILITIES

logfire.configure()
logging.basicConfig(level=logging.INFO)

MAX_CORRECTION_ATTEMPTS = 3

async def main():
    registry.autodiscover()
    logging.info(f"Worker started. Autodiscovered agents: {registry.list_agents()}")
    
    while True:
        task = task_queue.consume_task()
        if not task:
            continue

        with logfire.span("worker.process_task", task_id=task.id, capability=task.capability) as span:
            logging.info(f"Processing task {task.id} for capability '{task.capability}'")
            
            # Human-in-the-Loop Approval Gate
            if task.capability in CRITICAL_CAPABILITIES:
                logging.warning(f"Task {task.id} requires approval. Publishing to pending_approval queue.")
                task_queue.publish_for_approval(task)
                span.set_attribute("status", "pending_approval")
                continue

            target_agent = None
            deps = None
            for agent_name, (agent, caps, deps_fac) in registry.items():
                if task.capability in caps:
                    target_agent = agent
                    if deps_fac:
                        deps = deps_fac()
                    break
            
            if not target_agent:
                logging.error(f"No agent found for capability '{task.capability}' in task {task.id}")
                span.set_attribute("error", "No agent found")
                continue

            prompt = task.prompt
            for attempt in range(MAX_CORRECTION_ATTEMPTS):
                relevant_memories = await long_term_memory.get_relevant_memories(prompt)
                if relevant_memories:
                    context = "Relevant information from past activities:\n"
                    for mem in relevant_memories:
                        context += f"- {mem.content}\n"
                    prompt_with_context = f"{context}\n---\nOriginal Task:\n{prompt}"
                else:
                    prompt_with_context = prompt
                
                span.set_attribute("context_size", len(prompt_with_context))
                
                try:
                    if deps is None:
                        deps = {}
                    deps['working_memory'] = task.working_memory

                    res = await target_agent.run(prompt_with_context, deps=deps)
                    
                    if res.usage:
                        span.set_attribute("prompt_tokens", res.usage.prompt_tokens)
                        span.set_attribute("completion_tokens", res.usage.completion_tokens)

                    result_str = str(res.data)
                    
                    if task.capability == 'backend_dev' and result_str.endswith('.py'):
                        file_path = result_str
                        if os.path.exists(file_path):
                            lint_errors = lint_python_file(file_path)
                            if "No issues found." not in lint_errors:
                                logging.warning(f"Lint errors found in {file_path} on attempt {attempt + 1}. Re-invoking agent.")
                                with open(file_path, 'r') as f:
                                    code = f.read()
                                prompt = f"The following code has linting errors:\n\n{code}\n\nErrors:\n{lint_errors}\n\nPlease fix the code."
                                continue

                    updated_wm = task.working_memory.model_dump_json()
                    log_content = f"Task: {task.prompt}\nResponse: {result_str}\nWorking Memory: {updated_wm}"
                    await long_term_memory.add_memory(log_content)
                    
                    logging.info(f"Task {task.id} completed successfully.")
                    break

                except Exception as e:
                    logging.error(f"Task {task.id} failed on attempt {attempt + 1}: {e}")
                    span.set_attribute("error", str(e))
                    if attempt == MAX_CORRECTION_ATTEMPTS - 1:
                        logging.error(f"Task {task.id} failed after {MAX_CORRECTION_ATTEMPTS} attempts.")
                        break

if __name__ == "__main__":
    asyncio.run(main())
