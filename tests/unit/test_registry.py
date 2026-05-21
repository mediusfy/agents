"""Tests for the agent registry."""

import pytest

from openclaw.registry import AgentRegistry


def test_register_and_get():
    registry = AgentRegistry()
    fake_agent = object()
    registry.register("test-agent", fake_agent, ["test-cap"])
    assert registry.get("test-agent") is fake_agent


def test_register_duplicate_raises():
    registry = AgentRegistry()
    registry.register("dup", object(), ["cap1"])
    with pytest.raises(ValueError, match="already registered"):
        registry.register("dup", object(), ["cap2"])


def test_get_unregistered_raises():
    registry = AgentRegistry()
    with pytest.raises(ValueError, match="not registered"):
        registry.get("nonexistent")


def test_unregister():
    registry = AgentRegistry()
    registry.register("temp", object(), ["cap"])
    registry.unregister("temp")
    assert "temp" not in registry.list_agents()


def test_list_agents():
    registry = AgentRegistry()
    registry.register("a1", object(), ["cap"])
    registry.register("a2", object(), ["cap"])
    agents = registry.list_agents()
    assert "a1" in agents
    assert "a2" in agents
    assert len(agents) == 2


def test_autodiscover_imports_agents():
    """Minimal test: autodiscover imports agent modules without raising."""
    registry = AgentRegistry()
    # Autodiscover imports all agent modules (side-effect: instantiates Agent objects).
    # Registration is handled separately via registration.register_a2a_agents().
    registry.autodiscover()
    # Agents are accessible via their module-level variables, not self-registered.
    from openclaw.agents.accountant import accountant_agent
    from openclaw.agents.backend import backend_agent

    assert accountant_agent is not None
    assert backend_agent is not None
