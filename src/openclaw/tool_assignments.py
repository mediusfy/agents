AGENT_TOOL_CATEGORIES = {
    "ba": ["web", "memory", "documentation", "a2a"],
    "backend": ["web", "search", "security", "validation", "deps", "memory", "a2a"],
    "frontend": ["web", "search", "deps", "memory", "a2a"],
    "test_eng": ["search", "validation", "memory", "a2a"],
    "sre": ["web", "security", "validation", "deps", "memory", "a2a"],
    "quality_gate": ["validation", "memory", "a2a"],
    "review": ["security", "memory", "documentation", "a2a"],
    "security": ["search", "security", "memory", "a2a"],
    "docs": ["web", "documentation", "a2a"],
    "cto": ["search", "memory", "documentation", "a2a"]
}

def get_tool_categories(agent_name: str) -> list[str]:
    return AGENT_TOOL_CATEGORIES.get(agent_name, [])
