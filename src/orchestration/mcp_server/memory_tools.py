"""Memory bridge MCP tools — sync memory across runtimes, check status."""

import logging

import logfire

from orchestration.mcp_server import mcp
from orchestration.memory_bridge import get_bridge_status, sync_claude_to_pgvector, sync_memory_to_claude

logger = logging.getLogger(__name__)


@mcp.tool()
async def sync_memory(all_runtimes: bool = True, max_entries: int = 50) -> str:
    """Sync memory across all agent runtimes (pgvector ↔ Claude Code ↔ Antigravity).

    First pushes recent pgvector activity logs into Claude Code's agent-memory
    files and Antigravity's implicit memory. Then pulls Claude Code's memory
    back into pgvector for discovery by Orgitration agents.

    Args:
        all_runtimes: If True, sync to both Claude Code and Antigravity.
                      If False, only sync pgvector → Claude Code.
        max_entries: Max recent pgvector entries to process.
    """
    with logfire.span("mcp.sync_memory", all_runtimes=all_runtimes, _level="info"):
        synced_count = await sync_memory_to_claude(max_entries=max_entries)
        pulled_count = await sync_claude_to_pgvector()

    return (
        f"Memory sync complete:\n"
        f"  pgvector → Claude Code: {synced_count} entries\n"
        f"  Claude Code → pgvector: {pulled_count} entries"
    )


@mcp.tool()
async def memory_bridge_status() -> str:
    """Get the current status of all memory systems (pgvector, Claude Code, Antigravity).

    Reports how many memory files each Claude Code agent has, how many
    Antigravity implicit entries exist, and pgvector table health.
    """
    status = await get_bridge_status()
    return (
        f"Memory Bridge Status:\n"
        f"  Claude Code agents: {len(status.get('claude_agent_memory', {}))}\n"
        f"  Claude memory files: {status.get('claude_agent_memory', {})}\n"
        f"  Antigravity implicit entries: {status.get('antigravity_implicit_count', 0)}\n"
        f"  pgvector tables active: {list(status.get('pgvector_tables', {}).keys())}\n"
        f"  Runtime: Orgitration ↔ Claude Code ↔ Antigravity"
    )
