"""Bridge: pydantic_ai Agents / StageRunners → LangGraph node functions."""

import asyncio
from typing import Any

from orchestration.adapters.agents import AgentProviderPort
from orchestration.models.core import PipelineState
from orchestration.registry import registry


async def as_langgraph_node(
    state: PipelineState,
    *,
    agent_name: str,
    provider: AgentProviderPort,
    prompt: str | None = None,
) -> dict[str, Any]:
    """Run a registered pydantic_ai Agent as a LangGraph node.

    Returns a state delta dict that LangGraph merges into the shared state.
    """
    agent = registry.get(agent_name)
    resolved_prompt = prompt or _default_prompt(state, agent_name)
    try:
        result = await provider.run_agent(asyncio.Semaphore(10), agent_name, agent, resolved_prompt)
        return _state_delta(state, agent_name, result)
    except Exception as e:
        return _error_delta(state, agent_name, str(e))


def _default_prompt(state: PipelineState, agent_name: str) -> str:
    if agent_name == "ba":
        return f"Refine these requirements into user stories:\n{state.requirement}"
    if agent_name == "cto":
        stories = "\n".join(f"- {s.id}: {s.title}\n  {s.gherkin}" for s in (state.user_stories or []))
        return f"Review these stories:\n{stories}"
    if agent_name == "backend":
        stories = "\n".join(f"- {s.id}: {s.title}\n  {s.gherkin}" for s in (state.user_stories or []))
        return f"Generate Go backend for:\n{stories}"
    return f"Process requirements: {state.requirement}"


def _state_delta(_state: PipelineState, agent_name: str, result: Any) -> dict[str, Any]:
    output = getattr(result, "data", getattr(result, "output", result))
    if agent_name == "ba":
        stories = output if isinstance(output, list) else []
        return {"user_stories": stories, "stage": "ba"}
    if agent_name in ("cto", "ux"):
        recs = getattr(output, "recommendations", [])
        return {f"advisory_results.{agent_name}": "\n".join(recs) if recs else "(none)"}
    return {"stage": agent_name}


def _error_delta(state: PipelineState, agent_name: str, error: str) -> dict[str, Any]:
    return {"errors": state.errors + [f"{agent_name}: {error}"], "stage": agent_name}
