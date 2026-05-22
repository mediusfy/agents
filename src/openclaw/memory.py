import datetime
import hashlib
import logging
from typing import Any

from pydantic import BaseModel, Field

from openclaw.vector_db import vector_db

logger = logging.getLogger(__name__)


class Memory(BaseModel):
    content: str
    timestamp: str = Field(default_factory=lambda: datetime.datetime.now().isoformat())
    metadata: dict[str, Any] = Field(default_factory=dict)


class VectorMemory:
    def __init__(self, collection_name: str):
        self.collection_name = collection_name

    async def add_memory(self, content: str, metadata: dict[str, Any] | None = None):
        """Adds a new memory to the vector store with a stable content-based ID."""
        memory = Memory(content=content, metadata=metadata or {})
        content_hash = hashlib.md5(content.encode()).hexdigest()[:12]
        doc_id = f"memory_{memory.timestamp}_{content_hash}"
        await vector_db.async_add_documents(self.collection_name, [content], [memory.model_dump()], [doc_id])

    async def get_relevant_memories(self, query: str, n_results: int = 5) -> list[Memory]:
        """Retrieves the most relevant memories for a given query."""
        results = await vector_db.async_search(self.collection_name, query, n_results=n_results)
        return [Memory(content=res) for res in results]

    async def consolidate(self, n_recent: int = 50) -> str | None:
        """Fetch recent memories and return them as a single text block for summarization.

        Callers (agents or scheduled tasks) can pass the result to an LLM for
        summarization, then call add_memory() with the summary.
        Returns None if no memories found.
        """
        recent = await self.get_relevant_memories("activity:", n_results=n_recent)
        if not recent:
            logger.info("No memories to consolidate.")
            return None

        lines = []
        for mem in recent:
            ts = mem.timestamp[:19] if len(mem.timestamp) > 19 else mem.timestamp
            meta = ""
            if mem.metadata:
                mtype = mem.metadata.get("type", "")
                agent = mem.metadata.get("agent_name", "")
                meta = f" [{mtype} by {agent}]".strip() if mtype or agent else ""
            lines.append(f"[{ts}]{meta} {mem.content}")

        logger.info("Fetched %d recent memories for consolidation.", len(lines))
        return "\n".join(lines)


# Global memory instance — uses same collection as tools/memory.py log_activity
long_term_memory = VectorMemory("activity_logs")
