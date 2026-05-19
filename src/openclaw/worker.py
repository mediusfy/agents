import logging
import asyncio
import logfire
from openclaw.task_queue import task_queue
from openclaw.registry import registry
from openclaw.memory import long_term_memory

logfire.configure()
logging.basicConfig(level=logging.INFO)

async def main():
    registry.autodiscover()
    logging.info(f"Worker started. Autodiscovered agents: {registry.list_agents()}")
    
    while True:
        task = task_queue.consume_task()
        if not task:
            continue

        with logfire.span("worker.process_task", task_id=task.id, capability=task.capability) as span:
            logging.info(f"Processing task {task.id} for capability '{task.capability}'")
            
            target_agent = None
            for agent_name, (agent, caps, deps_fac) in registry.items():
                if task.capability in caps:
                    target_agent = agent
                    break
            
            if not target_agent:
                logging.error(f"No agent found for capability '{task.capability}' in task {task.id}")
                span.set_attribute("error", "No agent found")
                continue

            relevant_memories = await long_term_memory.get_relevant_memories(task.prompt)
            if relevant_memories:
                context = "Relevant information from past activities:\n"
                for mem in relevant_memories:
                    context += f"- {mem.content}\n"
                prompt_with_context = f"{context}\n---\nOriginal Task:\n{task.prompt}"
            else:
                prompt_with_context = task.prompt
            
            span.set_attribute("context_size", len(prompt_with_context))
            
            try:
                res = await target_agent.run(prompt_with_context)
                
                if res.usage:
                    span.set_attribute("prompt_tokens", res.usage.prompt_tokens)
                    span.set_attribute("completion_tokens", res.usage.completion_tokens)

                result_str = str(res.data)
                await long_term_memory.add_memory(f"Task: {task.prompt}\nResponse: {result_str}")
                logging.info(f"Task {task.id} completed successfully.")

            except Exception as e:
                logging.error(f"Task {task.id} failed: {e}")
                span.set_attribute("error", str(e))

if __name__ == "__main__":
    asyncio.run(main())
