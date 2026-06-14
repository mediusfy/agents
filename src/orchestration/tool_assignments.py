CATEGORY_GROUPS = {
    "all": ["search", "memory", "a2a"],
    "sdlc_engineer": ["@all", "web", "deps", "validation", "security"],
    "web_all": ["@all", "web"],
}

AGENT_TOOL_CATEGORIES = {
    "ba": ["web", "memory", "documentation", "a2a"],
    "backend": ["@sdlc_engineer"],
    "frontend": ["@all", "web", "deps"],
    "frontend_component": ["@all", "web", "deps", "documentation"],
    "test_eng": ["@all", "validation"],
    "test_gen": ["@all", "validation"],
    "go_test": ["@all", "validation"],
    "sre": ["web", "security", "validation", "deps", "memory", "a2a"],
    "quality_gate": ["validation", "memory", "a2a"],
    "review": ["security", "memory", "documentation", "a2a"],
    "security": ["@all", "security"],
    "docs": ["web", "documentation", "a2a"],
    "cto": ["@all", "documentation"],
    "ux": ["@all", "web", "documentation"],
    "planner": ["@web_all", "planning"],
    "service_engineer": ["@all"],
    "price_analyst": ["@web_all", "pricing"],
    "holiday_planner": ["@web_all", "planning"],
    "market_shark": ["@web_all", "finance"],
    "crypto_oracle": ["web", "search", "memory", "finance", "news", "a2a"],
    "database": ["@all", "web", "documentation"],
    "devops": ["@all", "web", "documentation"],
    "accountant": ["@web_all"],
    "asymmetric_reviewer": ["@web_all"],
    "current_events": ["@web_all"],
    "region_analyzer": ["@web_all"],
    "weather": ["@web_all"],
}


def _expand_group(group_name: str, seen: set[str] | None = None) -> list[str]:
    """Recursively expand ``@group_name`` references to their category lists."""
    if seen is None:
        seen = set()
    key = group_name.lstrip("@")
    if key in seen:
        return []
    seen.add(key)
    members = CATEGORY_GROUPS.get(key, [])
    expanded: list[str] = []
    for m in members:
        if m.startswith("@"):
            expanded.extend(_expand_group(m, seen))
        else:
            expanded.append(m)
    return expanded


def get_tool_categories(agent_name: str) -> list[str]:
    raw = AGENT_TOOL_CATEGORIES.get(agent_name, [])
    expanded: list[str] = []
    seen: set[str] = set()
    for entry in raw:
        if entry.startswith("@"):
            for cat in _expand_group(entry):
                if cat not in seen:
                    seen.add(cat)
                    expanded.append(cat)
        else:
            if entry not in seen:
                seen.add(entry)
                expanded.append(entry)
    return expanded
