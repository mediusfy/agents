import os
import json
import uuid
import logging
from typing import Optional
from src.models.core import PipelineState
from src.config import AgentSettings

logger = logging.getLogger(__name__)

class CheckpointError(Exception):
    pass

class CheckpointManager:
    def __init__(self, project_name: str = "default", run_id: Optional[str] = None):
        self.project_name = project_name
        self.checkpoint_dir = os.path.join(AgentSettings.CHECKPOINT_DIR, project_name)
        os.makedirs(self.checkpoint_dir, exist_ok=True)
        self.run_id = run_id or str(uuid.uuid4())

    def _get_filepath(self, stage: str) -> str:
        safe_stage = stage.replace("/", "_").replace(" ", "_")
        return os.path.join(self.checkpoint_dir, f"{self.run_id}_{safe_stage}.json")

    def save(self, stage: str, state: PipelineState):
        filepath = self._get_filepath(stage)
        try:
            data = state.model_dump_json()
        except AttributeError:
            data = state.json()
        with open(filepath, "w") as f:
            f.write(data)
        logger.info(f"Checkpoint saved: stage='{stage}' at {os.path.relpath(filepath)}")

    def load(self, stage: str) -> Optional[PipelineState]:
        filepath = self._get_filepath(stage)
        if not os.path.exists(filepath):
            return None
        try:
            with open(filepath, "r") as f:
                data = json.load(f)
            try:
                return PipelineState.model_validate(data)
            except AttributeError:
                return PipelineState.parse_obj(data)
        except (json.JSONDecodeError, KeyError, TypeError) as e:
            logger.warning(f"Corrupted checkpoint for stage '{stage}': {e}")
            os.remove(filepath)
            return None

    def clear(self):
        if not os.path.isdir(self.checkpoint_dir):
            return
        count = 0
        for filename in os.listdir(self.checkpoint_dir):
            if filename.startswith(self.run_id):
                os.remove(os.path.join(self.checkpoint_dir, filename))
                count += 1
        logger.info(f"Checkpoints cleared: {count} files for run {self.run_id}")

    def find_latest_run_id(self) -> Optional[str]:
        if not os.path.isdir(self.checkpoint_dir):
            return None
        try:
            files = [f for f in os.listdir(self.checkpoint_dir) if f.endswith(".json")]
            if not files:
                return None
            files.sort(key=lambda x: os.path.getmtime(os.path.join(self.checkpoint_dir, x)), reverse=True)
            latest = files[0]
            run_id = latest.split("_")[0]
            try:
                uuid.UUID(run_id)
                return run_id
            except ValueError:
                return None
        except Exception as e:
            logger.warning(f"Error finding latest run: {e}")
            return None

    def stage_exists(self, stage: str) -> bool:
        return os.path.exists(self._get_filepath(stage))
