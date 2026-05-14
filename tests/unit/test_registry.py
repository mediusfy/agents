"""Tests for the agent registry."""

import pytest
from openclaw.registry import AgentRegistry


def test_register_and_get():
    registry = AgentRegistry()
    fake_agent = object()
    registry.register("test-agent", fake_agent)
    assert registry.get("test-agent") is fake_agent


def test_register_duplicate_raises():
    registry = AgentRegistry()
    registry.register("dup", object())
    with pytest.raises(ValueError, match="already registered"):
        registry.register("dup", object())


def test_get_unregistered_raises():
    registry = AgentRegistry()
    with pytest.raises(ValueError, match="not registered"):
        registry.get("nonexistent")


def test_unregister():
    registry = AgentRegistry()
    registry.register("temp", object())
    registry.unregister("temp")
    assert "temp" not in registry.list_agents()


def test_list_agents():
    registry = AgentRegistry()
    registry.register("a1", object())
    registry.register("a2", object())
    agents = registry.list_agents()
    assert "a1" in agents
    assert "a2" in agents
    assert len(agents) == 2


def test_autodiscover_imports_agents():
    """Minimal test: autodiscover should not raise."""
    registry = AgentRegistry()
    registry.autodiscover()
    agents = registry.list_agents()
    assert len(agents) > 0
