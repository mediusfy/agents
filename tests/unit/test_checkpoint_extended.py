import time
from pathlib import Path
import pytest
from openclaw.checkpoint import CheckpointManager
from openclaw.models.core import PipelineState


@pytest.fixture
def manager(tmp_path, monkeypatch):
    monkeypatch.setattr("openclaw.checkpoint.settings.checkpoint_dir", str(tmp_path))
    return CheckpointManager(project_name="test_proj", run_id="test_run")


@pytest.fixture
def sample_state():
    return PipelineState(run_id="test_run", stage="init", attempt=1)


class TestCheckpointSaveLoad:
    def test_round_trip(self, manager, sample_state):
        manager.save("stage1", sample_state)
        loaded = manager.load("stage1")
        assert loaded is not None
        assert loaded.run_id == "test_run"
        assert loaded.stage == "init"

    def test_load_nonexistent(self, manager):
        assert manager.load("does_not_exist") is None

    def test_load_corrupt_json(self, manager):
        filepath = Path(manager._get_filepath("corrupt"))
        filepath.parent.mkdir(parents=True, exist_ok=True)
        filepath.write_text("{invalid_json: true}")
        assert manager.load("corrupt") is None

    def test_multiple_stages(self, manager, sample_state):
        manager.save("stage_a", sample_state)
        manager.save("stage_b", sample_state)
        assert manager.stage_exists("stage_a")
        assert manager.stage_exists("stage_b")


class TestCheckpointClear:
    def test_clear_removes_run_files(self, manager, sample_state):
        manager.save("stage1", sample_state)
        manager.save("stage2", sample_state)
        manager.clear()
        assert not manager.stage_exists("stage1")
        assert not manager.stage_exists("stage2")

    def test_clear_other_run_unaffected(self, manager, sample_state, tmp_path, monkeypatch):
        monkeypatch.setattr("openclaw.checkpoint.settings.checkpoint_dir", str(tmp_path))
        other = CheckpointManager(project_name="test_proj", run_id="other_run")
        manager.save("stage1", sample_state)
        other.save("stage_other", sample_state)
        manager.clear()
        assert other.stage_exists("stage_other")


class TestFindLatestRun:
    def test_no_checkpoints_returns_none(self, tmp_path, monkeypatch):
        monkeypatch.setattr("openclaw.checkpoint.settings.checkpoint_dir", str(tmp_path))
        m = CheckpointManager("empty")
        assert m.find_latest_run_id() is None

    def test_finds_latest_by_mtime(self, manager, tmp_path, monkeypatch):
        monkeypatch.setattr("openclaw.checkpoint.settings.checkpoint_dir", str(tmp_path))
        run_a = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        run_b = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        older = CheckpointManager("test_proj", run_id=run_a)
        older.save("s", PipelineState(run_id=run_a, stage="s"))
        time.sleep(0.01)
        newer = CheckpointManager("test_proj", run_id=run_b)
        newer.save("s", PipelineState(run_id=run_b, stage="s"))

        latest = CheckpointManager("test_proj").find_latest_run_id()
        assert latest == run_b
