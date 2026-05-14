"""Extended tests for the A2A agent bus."""

import pytest
import asyncio
from unittest.mock import MagicMock
from openclaw.a2a import AgentBus


class MockAgent:
    def __init__(self, return_value="default"):
        self.return_value = return_value

    async def run(self, prompt, deps=None):
        mock_result = MagicMock()
        mock_result.data = self.return_value
        return mock_result


@pytest.fixture
def bus():
    return AgentBus()


@pytest.fixture
def populated_bus(bus):
    bus.register("agent1", MockAgent("result1"), ["cap1"])
    bus.register("agent2", MockAgent("result2"), ["cap2"])
    return bus


class TestAgentBusRegistration:
    def test_register_agent(self, bus):
        bus.register("test", MockAgent(), ["cap"])
        assert "test" in bus.registry

    def test_register_with_deps_factory(self, bus):
        factory = lambda: object()  # noqa: E731
        bus.register("test", MockAgent(), ["cap"], factory)
        name, (agent, caps, fac) = "test", bus.registry["test"]
        assert fac is factory


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
            nonlocal deps_factory_called
            mock = MagicMock()
            mock.data = f"deps={deps}"
            return mock

        agent.run = run_with_deps
        bus.register("deps_agent", agent, ["needs_deps"], deps_factory)
        result = asyncio.run(bus.query("needs_deps", "test"))
        assert deps_factory_called
