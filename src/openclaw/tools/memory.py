import datetime
import json
from typing import List, Optional
from pydantic_ai import RunContext
from openclaw.vector_db import vector_db
from openclaw.models.core import ActivityLog
from openclaw.tools.registry import register_tool

async def log_activity(ctx: RunContext[any], action: str, summary: str, artifact_ids: Optional[List[str]] = None) -> str:
    """Logs a significant agent activity to the project memory for future spot-checking."""
    # In a real system, we'd get pass_num from ctx.deps or a global state
    pass_num = getattr(ctx.deps, "pass_num", 0)
    agent_name = getattr(ctx.deps, "agent_name", "unknown")
    
    log_entry = ActivityLog(
        pass_num=pass_num,
        agent_name=agent_name,
        action=action,
        summary=summary,
        timestamp=datetime.datetime.now().isoformat(),
        artifact_ids=artifact_ids or []
    )
    
    doc_id = f"log_{pass_num}_{agent_name}_{datetime.datetime.now().timestamp()}"
    narrative_doc = f"During pass {pass_num}, the {agent_name} agent performed an action: {action}. Summary: {summary}"
    
    await vector_db.async_add_documents(
        "activity_logs",
        [narrative_doc],
        [{"json_data": log_entry.model_dump_json(), "type": "activity"}],
        [doc_id]
    )
    return f"Activity logged successfully: {action}"

async def query_history(ctx: RunContext[any], query: str, pass_num: Optional[int] = None) -> str:
    """Queries the project history to find past decisions or actions."""
    results = await vector_db.async_search("activity_logs", query, n_results=5)
    if not results:
        return "No relevant history found."
    
    formatted_logs = []
    for res in results:
        try:
            log = json.loads(res)
            formatted_logs.append(f"Pass {log['pass_num']} | {log['agent_name']} | {log['action']}: {log['summary']}")
        except:
            
    return "Relevant Project History:\n" + "\n".join(formatted_logs)

async def read_and_memorize_url(ctx: RunContext[any], url: str) -> str:
    """Reads a large webpage, splits it into semantic chunks, and saves it directly to memory."""
    try:
        return await vector_db.async_ingest_url("knowledge_base", url)
    except Exception as e:
        return f"Failed to ingest URL: {e}"

async def read_and_memorize_pdf(ctx: RunContext[any], file_path: str) -> str:
    """Reads a PDF document, splits it into semantic chunks, and saves it directly to memory."""
    try:
        return await vector_db.async_ingest_pdf("knowledge_base", file_path)
    except Exception as e:
        return f"Failed to ingest PDF: {e}"

register_tool("log_activity", log_activity, "Logs activity to project memory", ["memory"])
register_tool("query_history", query_history, "Queries project history", ["memory"])
register_tool("read_and_memorize_url", read_and_memorize_url, "Scrapes and memorizes large webpages", ["memory", "web", "research", "news"])
register_tool("read_and_memorize_pdf", read_and_memorize_pdf, "Reads and memorizes PDF documents", ["memory", "research", "documentation"])
