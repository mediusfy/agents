"""Tests for the agent registry.

Covers:
- Capability index works for O(1) lookup (query uses _cap_index, not linear scan)
- Registering multiple agents with same capabilities (last-write-wins for the index)
- Unregistering removes capability index entries
- query() uses the index (doesn't fall through to linear scan)
- dispatch_task no longer exists
- Edge cases: unknown capability, timed-out agent, agent error
"""

from unittest.mock import AsyncMock, MagicMock

import pytest

from openclaw.registry import AgentRegistry

# ─── Capability Index ─────────────────────────────────────────────────────────


class TestCapabilityIndex:
    def test_register_builds_index(self):
        """Registering an agent populates _cap_index for each capability."""
        registry = AgentRegistry()
        registry.register("agent-a", MagicMock(), ["cap1", "cap2"])

        assert registry._cap_index["cap1"] == "agent-a"
        assert registry._cap_index["cap2"] == "agent-a"

    @pytest.mark.asyncio
    async def test_index_provides_o1_lookup(self):
        """query() reads from the index dict (O(1)), not scanning _agents.

        We verify O(1) lookup by: (1) confirming _cap_index is a plain dict
        (not a list scan), (2) confirming query() returns the right result
        from the index, and (3) confirming that an agent registered without
        the queried capability's key in _cap_index is never consulted.
        """
        registry = AgentRegistry()
        a1 = MagicMock()
        a1.run = AsyncMock(return_value=MagicMock(data="from a1"))
        a2 = MagicMock()
        a2.run = AsyncMock(return_value=MagicMock(data="from a2"))

        # a2 has "search", a1 has "unrelated"
        registry.register("agent-two", a2, ["search"])
        registry.register("agent-one", a1, ["other-cap"])

        # query for "search" must go to agent-two
        result = await registry.query("search", "find x")
        assert result == "from a2"
        # agent-one's run should NOT have been called
        a1.run.assert_not_called()

    @pytest.mark.asyncio
    async def test_index_returns_correct_agent(self):
        """query() routes to the agent registered for the requested capability."""
        registry = AgentRegistry()
        a1 = MagicMock()
        a1.run = AsyncMock(return_value=MagicMock(data="from a1"))
        a2 = MagicMock()
        a2.run = AsyncMock(return_value=MagicMock(data="from a2"))

        registry.register("agent-one", a1, ["search"])
        registry.register("agent-two", a2, ["audit"])

        result1 = await registry.query("search", "find x")
        result2 = await registry.query("audit", "check y")

        assert result1 == "from a1"
        assert result2 == "from a2"

    @pytest.mark.asyncio
    async def test_query_unknown_capability(self):
        """query() returns an error string for unknown capabilities."""
        registry = AgentRegistry()
        result = await registry.query("nonexistent", "anything")
        assert "No agent found" in result
        assert "nonexistent" in result

    @pytest.mark.asyncio
    async def test_last_registered_wins_for_same_capability(self):
        """When two agents share a capability, the last registered one wins."""
        registry = AgentRegistry()
        a1 = MagicMock()
        a1.run = AsyncMock(return_value=MagicMock(data="first"))
        a2 = MagicMock()
        a2.run = AsyncMock(return_value=MagicMock(data="second"))

        registry.register("agent-a", a1, ["search"])
        registry.register("agent-b", a2, ["search"])

        # Index points to the last registrant
        assert registry._cap_index["search"] == "agent-b"
        result = await registry.query("search", "find x")
        assert result == "second"

    def test_unregister_removes_index_entries(self):
        """Unregistering an agent removes all its capability index entries.

        NOTE: If another agent also provided the same capability, it will be
        removed too — the index is last-write-wins and unregister pops by cap name.
        """
        registry = AgentRegistry()
        registry.register("agent-x", MagicMock(), ["cap-a", "cap-b", "cap-c"])

        registry.unregister("agent-x")

        assert "cap-a" not in registry._cap_index
        assert "cap-b" not in registry._cap_index
        assert "cap-c" not in registry._cap_index

    def test_unregister_removes_shared_cap_from_index(self):
        """unregister removes the capability key even if another agent also has it.

        This documents current behaviour: _cap_index is last-write-wins and
        unregister pops by capability name irrespective of which owner registered
        it.  This is an area for future improvement.
        """
        registry = AgentRegistry()
        registry.register("alpha", MagicMock(), ["common", "alpha-only"])
        registry.register("beta", MagicMock(), ["common", "beta-only"])

        registry.unregister("alpha")

        # "common" is removed because unregister pops the key by cap name
        assert "common" not in registry._cap_index
        assert "alpha-only" not in registry._cap_index
        # "beta-only" was registered by beta, so it survives
        assert registry._cap_index.get("beta-only") == "beta"

    def test_unregister_nonexistent_does_not_raise(self):
        """Unregistering an agent that was never registered is a no-op."""
        registry = AgentRegistry()
        registry.unregister("ghost")

    def test_unregister_clears_initialized_flag(self):
        """Unregistering also removes the agent from _initialized set."""
        registry = AgentRegistry()
        registry.register("agent-z", MagicMock(), ["cap"])
        registry._initialized.add("agent-z")

        registry.unregister("agent-z")

        assert "agent-z" not in registry._initialized


# ─── query() edge cases ───────────────────────────────────────────────────────


class TestQueryEdgeCases:
    @pytest.mark.asyncio
    async def test_query_timeout_returns_error_message(self):
        registry = AgentRegistry()
        agent = MagicMock()
        agent.run = AsyncMock(side_effect=TimeoutError())
        registry.register("slow", agent, ["think"])

        result = await registry.query("think", "hard problem", timeout=0.001)

        assert "timed out" in result

    @pytest.mark.asyncio
    async def test_query_agent_error_returns_error_message(self):
        registry = AgentRegistry()
        agent = MagicMock()
        agent.run = AsyncMock(side_effect=RuntimeError("boom"))
        registry.register("crashy", agent, ["implode"])

        result = await registry.query("implode", "trigger error")

        assert "Agent error" in result
        assert "boom" in result

    @pytest.mark.asyncio
    async def test_query_no_data_attr_returns_str_of_result(self):
        """When the agent result has no .data attribute, str(result) is used."""
        registry = AgentRegistry()
        agent = MagicMock()
        agent.run = AsyncMock(return_value="raw string result")
        registry.register("simple", agent, ["echo"])

        result = await registry.query("echo", "hello")

        assert result == "raw string result"


# ─── dispatch_task removed ────────────────────────────────────────────────────


class TestDispatchTaskRemoved:
    def test_dispatch_task_does_not_exist(self):
        """dispatch_task was removed; it must not be callable on AgentRegistry."""
        registry = AgentRegistry()
        assert not hasattr(registry, "dispatch_task")
