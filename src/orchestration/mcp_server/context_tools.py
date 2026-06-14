"""Context/knowledge-base MCP tools — ADR search, project seeding, context queries."""

import glob
import logging
import os

import logfire

from orchestration.mcp_server import mcp
from orchestration.vector_db import vector_db

logger = logging.getLogger(__name__)


@mcp.tool()
async def search_adrs(query: str) -> str:
    """Search existing Architecture Decision Records (ADRs) to ensure new advice doesn't contradict past rulings."""
    with logfire.span("mcp.search_adrs", query_length=len(query), _level="info"):
        results = await vector_db.search("adrs", query)
        if not results:
            return f"No ADRs found for query: {query}"
        return "Found past architectural context:\n" + "\n---\n".join(results)


@mcp.tool()
async def save_adr(decision_id: str, content: str) -> str:
    """Save a new Architecture Decision Record (ADR) to the knowledge base."""
    with logfire.span("mcp.save_adr", decision_id=decision_id, _level="info"):
        await vector_db.add_documents("adrs", [content], [{"id": decision_id}], [decision_id])
        return f"Saved ADR {decision_id} successfully."


@mcp.tool()
async def seed_project_context(project_path: str) -> str:
    """Seed the vector DB with project files (rules, workflows, READMEs, ADRs).

    Args:
        project_path: Absolute path to the project root.
    """
    files_indexed = 0
    errors = []

    patterns = [
        os.path.join(project_path, ".agents", "rules", "*.md"),
        os.path.join(project_path, ".agents", "workflows", "*.md"),
        os.path.join(project_path, ".agents", "rules", "**", "*.md"),
        os.path.join(project_path, ".agents", "workflows", "**", "*.md"),
        os.path.join(project_path, "**", "ARCHITECTURE*.md"),
        os.path.join(project_path, "**", "CONVENTIONS*.md"),
        os.path.join(project_path, "**", "CODING_STANDARDS*.md"),
        os.path.join(project_path, "**", "CONTRIBUTING*.md"),
        os.path.join(project_path, "**", "*.adr"),
        os.path.join(project_path, "*.md"),
    ]

    for pattern in patterns:
        matches = glob.glob(pattern, recursive=True)
        for fp in matches:
            if not os.path.isfile(fp):
                continue
            try:
                with open(fp, encoding="utf-8") as f:
                    content = f.read()
                if not content.strip():
                    continue

                rel = os.path.relpath(fp, project_path).lower()
                if "rule" in rel or "convention" in rel:
                    domain = "conventions"
                elif "adr" in rel or "architecture" in rel:
                    domain = "adrs"
                elif "workflow" in rel or "pipeline" in rel or "readme" in os.path.basename(fp).lower():
                    domain = "project"
                else:
                    domain = "architecture"

                sanitized = rel.replace("/", "::").replace(chr(92), "::")
                doc_id = f"file:{sanitized}"
                await vector_db.add_documents(
                    domain,
                    [content],
                    [{"source": fp, "domain": domain, "file": rel}],
                    [doc_id],
                )
                files_indexed += 1
            except Exception as e:
                errors.append(f"{fp}: {e}")

    summary = f"Indexed {files_indexed} files into vector DB"
    if files_indexed > 0:
        summary += " across domains: conventions, adrs, project, architecture"
    if errors:
        summary += f"\nErrors: {len(errors)}"
        for err in errors[:5]:
            summary += f"\n  - {err}"
    return summary


@mcp.tool()
async def query_context(query: str, domain: str = "", top_k: int = 5) -> str:
    """Query the vector DB directly for relevant context about any topic.

    Args:
        query: What to search for.
        domain: Optional domain filter (adrs, architecture, conventions, project).
                Empty string searches all domains.
        top_k: Max results per domain (default 5)
    """
    domains = [domain] if domain else ["adrs", "architecture", "conventions", "project"]
    all_results = []

    for d in domains:
        with logfire.span("mcp.query_context", domain=d, query_length=len(query), _level="info"):
            try:
                results = await vector_db.search(d, query, n_results=top_k)
                if results:
                    all_results.append(f"\n=== Domain: {d} ===")
                    for i, r in enumerate(results, 1):
                        snippet = r[:300] + "..." if len(r) > 300 else r
                        all_results.append(f"[{i}] {snippet}")
            except Exception as e:
                all_results.append(f"[Domain {d}] Error: {e}")

    if not all_results:
        return f"No context found for: {query}"

    return "\n".join(all_results)


@mcp.tool()
async def task_context(task_id: str) -> str:
    """Get full context from the vector DB about a specific completed async task.

    Searches the project domain for context related to a given task_id.
    """
    results = await vector_db.search("project", task_id, n_results=3)
    if not results:
        return f"No context found for task: {task_id}"
    return "\n---\n".join(results[:3])
