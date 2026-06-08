"""Pipeline factory — single source of truth for assembling an OpenClawPipeline.

Both the CLI (``main.py``) and the MCP background runner (``pipeline_jobs.py``)
construct a pipeline by:

1. Building a ``PipelineConfig``.
2. Constructing ``OpenClawPipeline(config)``.
3. Registering the four standard stages (``ba``, ``advisory``,
   ``implementation``, ``quality_gate``).

Step 3 was previously duplicated only inside ``main.py``. The MCP path skipped
it, producing a stage-less pipeline that crashed with ``KeyError`` on first
stage lookup. This module owns step 3 so both callers share one definition.

If you add or remove a default stage, edit ``build_default_pipeline`` here —
nowhere else.
"""

from __future__ import annotations

from openclaw.pipeline.config import PipelineConfig
from openclaw.pipeline.orchestrator import OpenClawPipeline
from openclaw.stages.advisory_stage import AdvisoryStage
from openclaw.stages.ba_stage import BAStage
from openclaw.stages.implementation_stage import ImplementationStage
from openclaw.stages.quality_gate_stage import QualityGateStage


def build_default_pipeline(config: PipelineConfig) -> OpenClawPipeline:
    """Construct an ``OpenClawPipeline`` with the four standard stages registered.

    Stage names must match the orchestrator's hardcoded ``ordered_stage_names``
    in ``pipeline/orchestrator.py`` (currently: ``ba`` → ``advisory`` →
    ``implementation`` → ``quality_gate``). Keep them in sync.

    Note: this does NOT call ``register_all_agents()`` or
    ``configure_observability()`` — those are process-startup concerns owned
    by the entrypoint (``main.py`` for CLI, module-load for ``mcp_server.py``).
    """
    pipeline = OpenClawPipeline(config)
    pipeline.register_stage("ba", BAStage())
    pipeline.register_stage("advisory", AdvisoryStage())
    pipeline.register_stage("implementation", ImplementationStage())
    pipeline.register_stage("quality_gate", QualityGateStage())
    return pipeline
