# pyrefly: ignore [missing-import]
import sys
import os
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from mcp.server.fastmcp import FastMCP
from src.vector_db import vector_db
import logging

logging.basicConfig(level=logging.INFO)

mcp = FastMCP("OpenClaw")

@mcp.tool()
def search_adrs(query: str) -> str:
    """Search existing Architecture Decision Records (ADRs) to ensure new advice doesn't contradict past rulings."""
    results = vector_db.search("adrs", query)
    if not results:
        return f"No ADRs found for query: {query}"
    return "Found past architectural context:\n" + "\n---\n".join(results)

@mcp.tool()
def save_adr(decision_id: str, content: str) -> str:
    """Save a new Architecture Decision Record (ADR) to the knowledge base."""
    vector_db.add_documents("adrs", [content], [{"id": decision_id}], [decision_id])
    return f"Saved ADR {decision_id} successfully."

@mcp.tool()
async def delegate_to_openclaw_agent(capability: str, context: str, task: str) -> str:
    """
    Delegate a heavy-lifting engineering task to the OpenClaw autonomous agent ecosystem.
    Available capabilities: 'requirements_analysis', 'arch_review', 'backend_dev', 'frontend_dev', 'infra_advice', 'db_schema', etc.
    """
    from src.a2a import agent_bus
    from src.registry import registry
    registry.autodiscover()
    
    full_prompt = f"Context from IDE:\n{context}\n\nTask:\n{task}"
    result = await agent_bus.query(capability, full_prompt)
    return result

@mcp.tool()
async def run_openclaw_pipeline(project_name: str, requirement: str) -> str:
    """Run the entire multi-agent OpenClaw pipeline end-to-end for a given project requirement."""
    from main import main
    import os
    os.environ["REQUIREMENT"] = requirement
    # We run it with auto_yes=True so it doesn't block waiting for human input in the MCP server
    await main(project=project_name, step="all", resume=False, auto_yes=True)
    return f"Pipeline completed for {project_name}. Artifacts written to disk."


if __name__ == "__main__":
    mcp.run()
