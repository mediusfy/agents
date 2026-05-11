# pyrefly: ignore [missing-import]
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

# add more tools

if __name__ == "__main__":
    mcp.run()
