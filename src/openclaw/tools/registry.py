from typing import Callable, List, Tuple, Dict, Optional

class ToolDef:
    def __init__(self, name: str, fn: Callable, description: str, categories: List[str]):
        self.name = name
        self.fn = fn
        self.description = description
        self.categories = categories

tool_registry: Dict[str, ToolDef] = {}

def register_tool(name: str, fn: Callable, description: str, categories: Optional[List[str]] = None):
    categories = categories or []
    tool_registry[name] = ToolDef(name, fn, description, categories)

def get_tools_for_agent(agent_name: str, categories: List[str]) -> List[Tuple[str, Callable]]:
    tools = []
    for tool_def in tool_registry.values():
        if any(cat in tool_def.categories for cat in categories) or agent_name in tool_def.categories:
            tools.append((tool_def.name, tool_def.fn))
    return tools

def apply_tools(agent, agent_name: str, categories: List[str]):
    tools = get_tools_for_agent(agent_name, categories)
    for name, fn in tools:
        agent.tool(fn)
