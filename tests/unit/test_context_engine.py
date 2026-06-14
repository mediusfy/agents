from unittest.mock import AsyncMock, patch

import pytest

from orchestration.context_engine import AGENT_CONTEXT_DOMAINS


class TestAgentContextDomains:
    def test_known_agents_have_domains(self):
        assert "backend" in AGENT_CONTEXT_DOMAINS
        assert "frontend" in AGENT_CONTEXT_DOMAINS
        assert len(AGENT_CONTEXT_DOMAINS["backend"]) >= 2

    def test_unknown_agent_falls_back(self):
        domains = AGENT_CONTEXT_DOMAINS.get("unknown", ["architecture", "project"])
        assert "architecture" in domains


class TestRetrieveContext:
    @pytest.mark.asyncio
    async def test_returns_results(self):
        from orchestration.context_engine import retrieve_context

        with patch("orchestration.context_engine.vector_db.search", AsyncMock(return_value=["result1", "result2"])):
            result = await retrieve_context("backend", "build payment system")
            assert "result1" in result
            assert "result2" in result

    @pytest.mark.asyncio
    async def test_empty_results_returns_empty_string(self):
        from orchestration.context_engine import retrieve_context

        with patch("orchestration.context_engine.vector_db.search", AsyncMock(return_value=[])):
            result = await retrieve_context("backend", "nothing relevant")
            assert result == ""

    @pytest.mark.asyncio
    async def test_search_error_returns_empty_string(self):
        from orchestration.context_engine import retrieve_context

        with patch("orchestration.context_engine.vector_db.search", AsyncMock(side_effect=Exception("db error"))):
            result = await retrieve_context("backend", "test")
            assert result == ""


class TestStoreArtifactContext:
    @pytest.mark.asyncio
    async def test_stores_document(self):
        from orchestration.context_engine import store_artifact_context

        with patch("orchestration.context_engine.vector_db.add_documents", AsyncMock()) as mock_add:
            await store_artifact_context("adrs", "some content", {"agent": "test"})
            mock_add.assert_awaited_once()
