import datetime
import json
from typing import List, Optional
from pydantic_ai import RunContext
from src.vector_db import vector_db
from src.models.core import ActivityLog
from src.tools.registry import register_tool

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
            formatted_logs.append(res)
            
    return "Relevant Project History:\n" + "\n".join(formatted_logs)

register_tool("log_activity", log_activity, "Logs activity to project memory", ["memory"])
register_tool("query_history", query_history, "Queries project history", ["memory"])
