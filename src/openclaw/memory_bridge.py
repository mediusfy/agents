    """Get the current status of all memory systems."""
    activity_count = len(
        vector_db.search("activity_logs", "", n_results=100)
    ) if vector_db.search("activity_logs", "", n_results=100) else "available"
    claude_agent_memory = claude_memory_count()
    antigravity_implicit = len(
        list(ANTIGRAVITY_IMPLICIT_DIR.glob("*.md"))
    ) if ANTIGRAVITY_IMPLICIT_DIR.exists() else 0
    antigravity_annotations = len(
        list(ANTIGRAVITY_ANNOTATIONS_DIR.glob("*"))
    ) if ANTIGRAVITY_ANNOTATIONS_DIR.exists() else 0
    return {
        "chromadb_collections": {
            "activity_logs": {"count": activity_count},
            "knowledge_base": {"count": "available"},
            "project": {"available": True},
        },
        "claude_agent_memory": claude_agent_memory,
        "antigravity_implicit_count": antigravity_implicit,
        "antigravity_annotations_count": antigravity_annotations,
    }
