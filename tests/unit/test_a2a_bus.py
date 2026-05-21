import asyncio
from unittest.mock import MagicMock

import pytest

from openclaw.a2a import AgentBus
from openclaw.registry import AgentRegistry


class MockAgent:
    def __init__(self, return_value="default"):
        self.return_value = return_value

    async def run(self, prompt, deps=None):
        mock_result = MagicMock()
        mock_result.data = self.return_value
        return mock_result


@pytest.fixture
def fresh_registry():
    """Return an isolated AgentRegistry for testing."""
    return AgentRegistry()


@pytest.fixture
def bus(fresh_registry):
    """Return an AgentBus backed by an isolated registry."""
    bus = AgentBus()
    bus.registry = fresh_registry
    return bus


@pytest.fixture
def populated_bus(bus):
    bus.register("agent1", MockAgent("result1"), ["cap1"])
    bus.register("agent2", MockAgent("result2"), ["cap2"])
    return bus


class TestAgentBusRegistration:
    def test_register_agent(self, bus, fresh_registry):
        bus.register("test_agent", MockAgent(), ["cap"])
        assert fresh_registry.list_agents() == ["test_agent"]

    def test_register_with_deps_factory(self, bus, fresh_registry):
        factory = lambda: object()  # noqa: E731
        bus.register("test_factory", MockAgent(), ["cap"], factory)
        _name, (agent, caps, fac, hook) = list(fresh_registry.items())[0]
        assert fac is factory

    def test_register_duplicate_raises(self, bus):
        bus.register("dup_agent", MockAgent(), ["cap1"])
        with pytest.raises(ValueError, match="already registered"):
            bus.register("dup_agent", MockAgent(), ["cap2"])


class TestAgentBusQuery:
    def test_successful_query(self, populated_bus):
        result = asyncio.run(populated_bus.query("cap1", "hello"))
        assert result == "result1"

    def test_no_agent_found(self, bus):
        result = asyncio.run(bus.query("nonexistent", "hello"))
        assert "No agent found" in result

    def test_timeout(self, bus):
        class SlowAgent:
            async def run(self, prompt, deps=None):
                await asyncio.sleep(10)
                mock = MagicMock()
                mock.data = "done"
                return mock

        bus.register("slow", SlowAgent(), ["slow"])
        result = asyncio.run(bus.query("slow", "hello", timeout=0.1))
        assert "timed out" in result

    def test_query_with_deps(self, bus):
        deps_factory_called = False

        def deps_factory():
            nonlocal deps_factory_called
            deps_factory_called = True
            return "deps-object"

        agent = MockAgent("deps-result")

        async def run_with_deps(prompt, deps=None):
            mock = MagicMock()
            mock.data = f"deps={deps}"
            return mock

        agent.run = run_with_deps
        bus.register("deps_agent", agent, ["needs_deps"], deps_factory)
        asyncio.run(bus.query("needs_deps", "test"))
        assert deps_factory_called
