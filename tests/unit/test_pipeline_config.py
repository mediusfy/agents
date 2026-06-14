import pytest

from orchestration.pipeline.config import BLUEPRINTS, PipelineConfig


class TestPipelineConfig:
    def test_default_blueprint(self):
        cfg = PipelineConfig()
        assert cfg.blueprint == "langgraph_full"

    def test_known_blueprints_are_valid(self):
        for _name, bp in BLUEPRINTS.items():
            assert "description" in bp
            assert "stages" in bp

    def test_langgraph_blueprint(self):
        cfg = PipelineConfig(blueprint="langgraph_full")
        assert cfg.blueprint == "langgraph_full"

    def test_unknown_blueprint_raises(self):
        with pytest.raises(ValueError, match="Unknown blueprint"):
            PipelineConfig(blueprint="nonexistent")

    def test_output_dir_is_project_isolated(self):
        cfg = PipelineConfig(project="myproj")
        assert "myproj" in str(cfg.output_dir())

    def test_requirement_propagates_to_state(self):
        cfg = PipelineConfig(requirement="Build a payment service")
        assert cfg.requirement == "Build a payment service"

    def test_target_root_from_project_mapping(self):
        cfg = PipelineConfig(project="test")
        assert cfg.target_root == "test"

    def test_all_blueprints_have_stages(self):
        for name, bp in BLUEPRINTS.items():
            assert "stages" in bp, f"{name} missing stages"
            assert len(bp["stages"]) > 0, f"{name} has no stages"
