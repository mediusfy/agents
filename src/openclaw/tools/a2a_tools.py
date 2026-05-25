from pydantic_ai import RunContext

from openclaw.exceptions import AgentExecutionError, AgentNotFoundError
from openclaw.registry import instrumented_query, registry
from openclaw.tools.registry import register_tool


async def discover_agent_capabilities(ctx: RunContext) -> str:
    """Lists all available capabilities that other agents can perform. Use this to find out who to delegate to."""
    caps = []
    for name, (_agent, agent_caps, _deps_fac, _post_hook) in registry.items():
        for cap in agent_caps:
            caps.append(f"- Capability: '{cap}' (provided by {name} agent)")
    if not caps:
        return "No agents currently registered with capabilities."
    return "Available Agent Capabilities for Delegation:\n" + "\n".join(caps)


async def delegate_to_agent(ctx: RunContext, capability: str, prompt: str, context_summary: str) -> str:
    """
    Delegate a sub-task to another agent based on their capability.
    To ensure proficient token usage and accurate responses:
    - prompt: The specific task/question for the sub-agent.
    - context_summary: Provide ONLY the absolutely necessary context (e.g. key code snippets or decisions). Do not dump full history.

    Routed through `instrumented_query` so the cross-agent hop is a child span,
    not an invisible call.
    """
    full_prompt = (
        f"--- DELEGATED TASK ---\n"
        f"Context provided by caller:\n{context_summary}\n\n"
        f"Task:\n{prompt}\n\n"
        f"Please provide an accurate and concise response."
    )
    try:
        return await instrumented_query(
            capability=capability,
            prompt=full_prompt,
            span_name="a2a.delegate",
            attributes={"capability": capability, "context_summary_length": len(context_summary)},
        )
    except (AgentNotFoundError, AgentExecutionError) as e:
        return f"ERROR: {e}"


register_tool("discover_agent_capabilities", discover_agent_capabilities, "Find out what other agents can do.", ["a2a"])
register_tool(
    "delegate_to_agent",
    delegate_to_agent,
    "Delegate a task to a sub-agent with concise context to save tokens.",
    ["a2a"],
)
