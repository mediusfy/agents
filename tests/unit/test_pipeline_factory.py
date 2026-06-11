import pytest

from orchestration.pipeline.config import PipelineConfig


class TestPipelineFactory:
    def test_build_default_pipeline(self):
        from orchestration.pipeline.factory import build_default_pipeline

        cfg = PipelineConfig()
        pipeline = build_default_pipeline(cfg)
        assert pipeline is not None
        assert hasattr(pipeline, "execute")

    def test_build_legacy(self):
        from orchestration.pipeline.factory import build_pipeline

        cfg = PipelineConfig(framework="legacy")
        pipeline = build_pipeline(cfg)
        assert pipeline is not None
        assert hasattr(pipeline, "execute")

    def test_build_langgraph(self):
        from orchestration.pipeline.factory import build_pipeline

        cfg = PipelineConfig(blueprint="langgraph_full", framework="langgraph")
        pipeline = build_pipeline(cfg)
        from orchestration.pipeline.protocols import PipelineOrchestrator
        assert isinstance(pipeline, PipelineOrchestrator)

    def test_build_crewai_missing_dep_when_not_installed(self):
        import importlib
        original = importlib.util.find_spec
        importlib.util.find_spec = lambda name: None if name == "crewai" else original(name)
        try:
            from orchestration.pipeline.factory import build_pipeline
            cfg = PipelineConfig(blueprint="crew_sdlc", framework="crewai")
            with pytest.raises(ImportError, match="crewai"):
                build_pipeline(cfg)
        finally:
            importlib.util.find_spec = original

    def test_build_autogen_missing_dep_when_not_installed(self):
        import importlib
        original = importlib.util.find_spec
        importlib.util.find_spec = lambda name: None if name == "pyautogen" else original(name)
        try:
            from orchestration.pipeline.factory import build_pipeline
            cfg = PipelineConfig(blueprint="autogen_sdlc", framework="autogen")
            with pytest.raises(ImportError, match="pyautogen"):
                build_pipeline(cfg)
        finally:
            importlib.util.find_spec = original

    def test_build_composite(self):
        from orchestration.pipeline.factory import build_pipeline

        cfg = PipelineConfig(blueprint="composite", framework="composite")
        pipeline = build_pipeline(cfg)
        from orchestration.pipeline.protocols import PipelineOrchestrator
        assert isinstance(pipeline, PipelineOrchestrator)

    def test_protocol_runtime_checkable(self):
        from orchestration.pipeline.protocols import PipelineOrchestrator

        class Fake:
            async def execute(self):
                pass

        assert isinstance(Fake(), PipelineOrchestrator)
