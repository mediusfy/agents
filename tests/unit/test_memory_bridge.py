from unittest.mock import AsyncMock, patch

import pytest

from orchestration.memory_bridge import _get_claude_agents, claude_memory_count


class TestGetClaudeAgents:
    def test_no_directory_returns_empty(self):
        with patch("orchestration.memory_bridge.CLAUDE_AGENTS_DIR") as mock_dir:
            mock_dir.exists.return_value = False
            agents = _get_claude_agents()
            assert agents == []

    def test_returns_agent_names(self):
        with patch("orchestration.memory_bridge.CLAUDE_AGENTS_DIR") as mock_dir:
            mock_dir.exists.return_value = True
            d1 = type("Dir", (), {"name": "agent1", "is_dir": lambda self: True})()
            d2 = type("Dir", (), {"name": "agent2", "is_dir": lambda self: True})()
            f1 = type("Dir", (), {"name": "file.txt", "is_dir": lambda self: False})()
            mock_dir.iterdir.return_value = [d1, d2, f1]
            agents = _get_claude_agents()
            assert agents == ["agent1", "agent2"]


class TestClaudeMemoryCount:
    def test_no_agents_returns_empty_dict(self):
        with patch("orchestration.memory_bridge._get_claude_agents", return_value=[]):
            counts = claude_memory_count()
            assert counts == {}


class TestSyncMemoryToClaude:
    @pytest.mark.asyncio
    async def test_no_agents_returns_zero(self):
        from orchestration.memory_bridge import sync_memory_to_claude

        with patch("orchestration.memory_bridge._get_claude_agents", return_value=[]):
            result = await sync_memory_to_claude(max_entries=10)
            assert result == 0

    @pytest.mark.asyncio
    async def test_vector_db_failure_returns_zero(self):
        from orchestration.memory_bridge import sync_memory_to_claude

        with (
            patch("orchestration.memory_bridge._get_claude_agents", return_value=["agent1"]),
            patch("orchestration.memory_bridge.vector_db.search", AsyncMock(side_effect=Exception("db error"))),
        ):
            result = await sync_memory_to_claude()
            assert result == 0


class TestSyncClaudeToPgvector:
    @pytest.mark.asyncio
    async def test_no_agents_returns_zero(self):
        from orchestration.memory_bridge import sync_claude_to_pgvector

        with patch("orchestration.memory_bridge._get_claude_agents", return_value=[]):
            result = await sync_claude_to_pgvector()
            assert result == 0
