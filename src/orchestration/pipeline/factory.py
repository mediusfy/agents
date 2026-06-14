"""Pipeline factory — single source of truth for assembling any pipeline.

All pipelines are built as LangGraph state machines. This factory is the
single entry point for both the CLI (main.py) and MCP background runs.
"""

from __future__ import annotations

import uuid

from orchestration.models.core import PipelineState
from orchestration.pipeline.config import PipelineConfig

# Lazy imports to avoid hard dependency on langgraph at module load time
_built_pipeline_cache: dict[str, PipelineOrchestrator] = {}


async def build_pipeline(config: PipelineConfig) -> PipelineOrchestrator:
    """Build a LangGraph pipeline for the given config.

    Results are cached by (project, blueprint) so resume works correctly.
    """
    from orchestration.adapters.agents import PydanticAIAgentProvider
    from orchestration.pipeline.langgraph.graphs import build_full_graph

    cache_key = f"{config.project}:{config.blueprint}"
    if cache_key in _built_pipeline_cache and config.resume:
        return _built_pipeline_cache[cache_key]

    provider = PydanticAIAgentProvider()
    graph = await build_full_graph(config, provider)
    pipeline = _GraphPipelineWrapper(graph, config)
    if config.resume:
        _built_pipeline_cache[cache_key] = pipeline
    return pipeline


class PipelineOrchestrator:
    """Protocol for pipeline orchestrators."""

    async def execute(self) -> PipelineState:
        raise NotImplementedError


class _GraphPipelineWrapper:
    """Wraps a compiled LangGraph for the ``execute()`` interface.

    Provides the ``async def execute()`` contract expected by callers
    (``main.py``, ``pipeline_jobs.py``).
    """

    def __init__(self, graph: object, config: PipelineConfig):
        self._graph = graph
        self._config = config

    async def execute(self) -> PipelineState:
        initial = PipelineState(
            run_id=f"run-{uuid.uuid4().hex[:8]}",
            stage="init",
            requirement=self._config.requirement or "",
        )
        final = await self._graph.ainvoke(initial)
        return final
