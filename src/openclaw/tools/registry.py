from collections.abc import Callable


class ToolDef:
    def __init__(self, name: str, fn: Callable, description: str, categories: list[str]):
        self.name = name
        self.fn = fn
        self.description = description
        self.categories = categories


tool_registry: dict[str, ToolDef] = {}


def register_tool(name: str, fn: Callable, description: str, categories: list[str] | None = None):
    categories = categories or []
    tool_registry[name] = ToolDef(name, fn, description, categories)


def get_tools_for_agent(agent_name: str, categories: list[str]) -> list[tuple[str, Callable]]:
    tools = []
    for tool_def in tool_registry.values():
        if any(cat in tool_def.categories for cat in categories) or agent_name in tool_def.categories:
            tools.append((tool_def.name, tool_def.fn))
    return tools


def apply_tools(agent, agent_name: str, categories: list[str]):
    tools = get_tools_for_agent(agent_name, categories)
    for name, fn in tools:
        if name not in agent._function_toolset.tools:
            agent.tool(fn)
