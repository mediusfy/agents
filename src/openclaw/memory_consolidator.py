from dagster import job, op, schedule
from openclaw.memory import long_term_memory
from pydantic_ai import Agent
import logging

logger = logging.getLogger(__name__)

consolidation_agent = Agent(
    system_prompt="You are a Memory Consolidation Agent. Your task is to read a collection of recent memories, identify key themes and insights, and create a concise summary. The summary should capture the most important information that will be useful for future tasks, while omitting redundant or trivial details."
)

@op
async def consolidate_memories_op():
    """
    This Dagster op fetches recent memories, uses an LLM to consolidate them,
    and saves the summary back to the long-term memory.
    """
    logger.info("Starting memory consolidation...")
    
    # fetch recent memories
    recent_memories = await long_term_memory.get_relevant_memories("Task:", n_results=50)
    
    if not recent_memories:
        logger.info("No recent memories to consolidate.")
        return

    # Prepare the prompt for the consolidation agent
    memory_text = "\n".join([mem.content for mem in recent_memories])
    prompt = f"Please consolidate the following recent memories into a concise summary:\n\n{memory_text}"
    
    # generate the summary
    summary_response = await consolidation_agent.run(prompt)
    summary = str(summary_response.data)
    
    # save to long-term memory
    await long_term_memory.add_memory(f"Consolidated Summary: {summary}", metadata={"type": "consolidation_summary"})
    
    logger.info(f"Memory consolidation complete. Summary saved.")

@job
def consolidate_memories_job():
    """The Dagster job for memory consolidation."""
    consolidate_memories_op()

@schedule(job=consolidate_memories_job, cron_schedule="0 0 * * *")
def daily_memory_consolidation_schedule():
    """This schedule runs the memory consolidation job every day at midnight."""
    return {}
