from pydantic_ai import RunContext

from openclaw.exceptions import AgentExecutionError, AgentNotFoundError
from openclaw.registry import instrumented_query, registry
from openclaw.session_recorder import current_run_context
from openclaw.tools.registry import register_tool

MAX_DELEGATION_DEPTH = 3


async def discover_agent_capabilities(ctx: RunContext) -> str:
    """Lists all available capabilities that other agents can perform.
    Use this to find out who to delegate to."""
    caps = []
    for name, (_agent, agent_caps, _deps_fac, _post_hook) in registry.items():
        for cap in agent_caps:
            caps.append(f"- Capability: '{cap}' (provided by {name} agent)")

    if not caps:
        return "No agents currently registered with capabilities."

    return "Available Agent Capabilities for Delegation:\n" + "\n".join(caps)


async def delegate_to_agent(ctx: RunContext, capability: str, prompt: str, context_summary: str) -> str:
    """Delegate a sub-task to another agent based on their capability.

    To ensure proficient token usage and accurate responses:
    - capability: Which agent capability to use (see discover_agent_capabilities)
    - prompt: The specific task/question for the target agent
    - context_summary: Provide ONLY the absolutely necessary context. Do not dump full history.
    """
    ctx_data = current_run_context.get()
    current_depth = ctx_data.get("delegation_depth", 0)

    if current_depth >= MAX_DELEGATION_DEPTH:
        return "ERROR: Maximum delegation depth reached. You must complete the task with the information you have."

    full_prompt = (
        f"--- DELEGATED TASK ---\n"
        f"Context provided by caller:\n{context_summary}\n\n"
        f"Task:\n{prompt}\n\n"
        f"Please provide an accurate and concise response."
    )

    attrs = {
        "capability": capability,
        "context_summary_length": len(context_summary),
        "prompt_length": len(prompt),
        "context_summary_preview": context_summary[:200],
        "caller_agent": ctx_data.get("agent_name", ""),
        "caller_pipeline_stage": ctx_data.get("pipeline_stage", ""),
        "caller_run_id": ctx_data.get("run_id", ""),
        "delegation_depth": current_depth + 1,
    }

    try:
        return await instrumented_query(
            capability=capability,
            prompt=full_prompt,
            span_name="a2a.delegate",
            attributes=attrs,
            delegation_depth=current_depth + 1,
        )
    except (AgentNotFoundError, AgentExecutionError) as e:
        return f"ERROR: {e}"


register_tool(
    "discover_agent_capabilities",
    discover_agent_capabilities,
    "Find out what other agents can do.",
    ["a2a"],
)

register_tool(
    "delegate_to_agent",
    delegate_to_agent,
    "Delegate a task to another agent with concise context to save tokens.",
    ["a2a"],
)
