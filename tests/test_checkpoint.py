import os
import pytest
from openclaw.checkpoint import CheckpointManager
from openclaw.models.core import PipelineState

@pytest.fixture
def temp_checkpoint_dir(tmp_path, monkeypatch):
    monkeypatch.setattr("openclaw.config.AgentSettings.CHECKPOINT_DIR", str(tmp_path))
    return tmp_path

def test_checkpoint_save_and_load(temp_checkpoint_dir):
    manager = CheckpointManager(project_name="test_proj", run_id="test_run")
    
    state = PipelineState(
        run_id="test_run",
        stage="init",
        attempt=1
    )
    
    manager.save("init", state)
    
    assert manager.stage_exists("init")
    
    loaded_state = manager.load("init")
    assert loaded_state is not None
    assert loaded_state.run_id == "test_run"
    assert loaded_state.stage == "init"

def test_checkpoint_load_nonexistent(temp_checkpoint_dir):
    manager = CheckpointManager(project_name="test_proj", run_id="test_run")
    loaded_state = manager.load("does_not_exist")
    assert loaded_state is None

def test_checkpoint_load_corrupt(temp_checkpoint_dir):
    manager = CheckpointManager(project_name="test_proj", run_id="test_run")
    filepath = manager._get_filepath("corrupt")
    os.makedirs(os.path.dirname(filepath), exist_ok=True)
    with open(filepath, "w") as f:
        f.write("{invalid_json: true")
        
    loaded_state = manager.load("corrupt")
    assert loaded_state is None
    # We removed os.remove, so the file should still exist
    assert os.path.exists(filepath)

def test_checkpoint_clear(temp_checkpoint_dir):
    manager = CheckpointManager(project_name="test_proj", run_id="test_run")
    state = PipelineState(run_id="test_run", stage="init")
    manager.save("init", state)
    
    manager.clear()
    assert not manager.stage_exists("init")
