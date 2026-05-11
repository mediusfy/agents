AGENT_TOOL_CATEGORIES = {
    "ba": ["web", "memory", "documentation"],
    "backend": ["web", "search", "security", "validation", "deps", "memory"],
    "frontend": ["web", "search", "deps", "memory"],
    "test_eng": ["search", "validation", "memory"],
    "sre": ["web", "security", "validation", "deps", "memory"],
    "quality_gate": ["validation", "memory"],
    "review": ["security", "memory", "documentation"],
    "security": ["search", "security", "memory"],
    "docs": ["web", "documentation"],
    "cto": ["search", "memory", "documentation"]
}

def get_tool_categories(agent_name: str) -> list[str]:
    return AGENT_TOOL_CATEGORIES.get(agent_name, [])
