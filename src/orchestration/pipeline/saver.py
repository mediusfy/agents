"""Checkpointer factory — creates a PostgresSaver (or MemorySaver fallback).

Phase 3.1 of the production-hardening plan: replaces in-memory ``MemorySaver``
with PostgreSQL-backed ``PostgresSaver`` for LangGraph checkpoint persistence.
"""

import logging
from typing import Any

from langgraph.checkpoint.memory import MemorySaver

from orchestration.pipeline.config import PipelineConfig
from orchestration.vector_db import _dsn

logger = logging.getLogger(__name__)


async def create_checkpointer(config: PipelineConfig) -> Any:
    """Create a LangGraph checkpointer backed by PostgreSQL.

    Falls back to ``MemorySaver`` when the ``langgraph-checkpoint-postgres``
    package is unavailable or the database connection fails.
    """
    if not config.resume:
        return None

    try:
        from langgraph.checkpoint.postgres import PostgresSaver

        conn_string = _dsn()
        saver = PostgresSaver.from_conn_string(conn_string)
        await saver.setup()
        logger.info("PostgresSaver checkpointer created (resume=%s)", config.resume)
        return saver
    except Exception:
        logger.warning("PostgresSaver unavailable, falling back to MemorySaver")
        return MemorySaver()
