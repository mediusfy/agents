AGENT_TOOL_CATEGORIES = {
    "ba": ["web"],
    "backend": ["web", "search", "security", "validation", "deps"],
    "frontend": ["web", "search", "deps"],
    "test_eng": ["search", "validation"],
    "sre": ["web", "security", "validation", "deps"],
    "quality_gate": ["validation"],
    "review": ["security"],
    "security": ["search", "security"],
    "docs": ["web"],
}

def get_tool_categories(agent_name: str) -> list[str]:
    return AGENT_TOOL_CATEGORIES.get(agent_name, [])
