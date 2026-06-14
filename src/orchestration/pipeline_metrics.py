"""Pipeline execution metrics — per-stage timing, agent call counts, retries.

Hooks into Logfire spans to track pipeline performance and exposes
``get_pipeline_metrics(run_id)`` for querying.
"""

import time
from typing import Any

import logfire


class PipelineMetrics:
    """Collects and exposes per-run pipeline execution metrics.

    Metrics are stored in a dict keyed by ``run_id`` and are queryable
    via ``get_pipeline_metrics()``.
    """

    def __init__(self):
        self._store: dict[str, dict[str, Any]] = {}

    def init_run(self, run_id: str) -> None:
        self._store[run_id] = {
            "run_id": run_id,
            "stages": {},
            "agent_call_count": 0,
            "retry_count": 0,
            "gate_pass_count": 0,
            "gate_fail_count": 0,
            "started_at": time.time(),
            "completed_at": None,
        }

    def start_stage(self, run_id: str, stage_name: str) -> None:
        run = self._store.get(run_id)
        if run is None:
            return
        run["stages"][stage_name] = {
            "name": stage_name,
            "started_at": time.time(),
            "completed_at": None,
            "duration_sec": None,
        }

    def end_stage(self, run_id: str, stage_name: str) -> None:
        run = self._store.get(run_id)
        if run is None:
            return
        stage = run["stages"].get(stage_name)
        if stage is None:
            return
        now = time.time()
        stage["completed_at"] = now
        stage["duration_sec"] = now - stage["started_at"]

    def record_agent_call(self, run_id: str) -> None:
        run = self._store.get(run_id)
        if run is not None:
            run["agent_call_count"] += 1

    def record_retry(self, run_id: str) -> None:
        run = self._store.get(run_id)
        if run is not None:
            run["retry_count"] += 1

    def record_gate_result(self, run_id: str, passed: bool) -> None:
        run = self._store.get(run_id)
        if run is not None:
            if passed:
                run["gate_pass_count"] += 1
            else:
                run["gate_fail_count"] += 1

    def complete_run(self, run_id: str) -> None:
        run = self._store.get(run_id)
        if run is not None:
            run["completed_at"] = time.time()

    def get_metrics(self, run_id: str) -> dict[str, Any] | None:
        return self._store.get(run_id)

    def logfire_span(self, run_id: str, stage_name: str):
        """Context manager that wraps a stage with a Logfire span and auto-records timing."""
        return _LogfireStageSpan(self, run_id, stage_name)


class _LogfireStageSpan:
    def __init__(self, metrics: PipelineMetrics, run_id: str, stage_name: str):
        self._metrics = metrics
        self._run_id = run_id
        self._stage_name = stage_name

    async def __aenter__(self):
        self._metrics.start_stage(self._run_id, self._stage_name)
        self._span = logfire.span(
            f"pipeline.stage.{self._stage_name}",
            run_id=self._run_id,
            stage=self._stage_name,
            _level="info",
        )
        self._span.__enter__()
        return self

    async def __aexit__(self, *args):
        self._metrics.end_stage(self._run_id, self._stage_name)
        self._span.__exit__(*args)


pipeline_metrics = PipelineMetrics()
