import asyncio
from unittest.mock import MagicMock

from openclaw.a2a import AgentBus


class MockAgent:
    def __init__(self, return_value):
        self.return_value = return_value

    async def run(self, prompt, deps=None):
        mock_result = MagicMock()
        mock_result.data = self.return_value
        return mock_result


def test_a2a_successful_query():
    bus = AgentBus()
    agent = MockAgent(return_value="mocked response")
    bus.register("test_agent", agent, ["test_cap"])

    result = asyncio.run(bus.query("test_cap", "hello"))
    assert result == "mocked response"


def test_a2a_no_agent_found():
    bus = AgentBus()
    result = asyncio.run(bus.query("nonexistent_cap", "hello"))
    assert "No agent found" in result


def test_a2a_timeout():
    bus = AgentBus()

    class SlowAgent:
        async def run(self, prompt, deps=None):
            await asyncio.sleep(2)
            mock_result = MagicMock()
            mock_result.data = "done"
            return mock_result

    bus.register("slow_agent", SlowAgent(), ["slow_cap"])
    result = asyncio.run(bus.query("slow_cap", "hello", timeout=0.1))
    assert "timed out" in result
