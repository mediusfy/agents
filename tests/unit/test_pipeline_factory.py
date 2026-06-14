import pytest

from orchestration.pipeline.config import PipelineConfig


class TestPipelineFactory:
    @pytest.mark.asyncio
    async def test_build_pipeline(self):
        from orchestration.pipeline.factory import build_pipeline

        cfg = PipelineConfig()
        pipeline = await build_pipeline(cfg)
        assert pipeline is not None
        assert hasattr(pipeline, "execute")

    @pytest.mark.asyncio
    async def test_build_langgraph(self):
        from orchestration.pipeline.factory import build_pipeline

        cfg = PipelineConfig(blueprint="langgraph_full")
        pipeline = await build_pipeline(cfg)
        assert hasattr(pipeline, "execute")

    @pytest.mark.asyncio
    async def test_build_with_requirement(self):
        from orchestration.pipeline.factory import build_pipeline

        cfg = PipelineConfig(blueprint="langgraph_full", requirement="Build a payment service")
        pipeline = await build_pipeline(cfg)
        assert pipeline is not None

    @pytest.mark.asyncio
    async def test_build_quick_backend(self):
        from orchestration.pipeline.factory import build_pipeline

        cfg = PipelineConfig(blueprint="langgraph_quick")
        pipeline = await build_pipeline(cfg)
        assert pipeline is not None

    def test_unknown_blueprint_raises(self):
        with pytest.raises(ValueError, match="Unknown blueprint"):
            PipelineConfig(blueprint="nonexistent")
