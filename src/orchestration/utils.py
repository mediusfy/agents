from pathlib import Path
from typing import Any

from orchestration.exceptions import PathTraversalError


def safe_path_join(base: str | Path, *parts: str) -> Path:
    """Join path components and verify the result stays within base.
    Raises PathTraversalError if the resolved path escapes base.
    """
    base_resolved = Path(base).resolve()
    full = base_resolved.joinpath(*parts).resolve()
    if not str(full).startswith(str(base_resolved)):
        raise PathTraversalError(f"Path traversal detected: {'/'.join(parts)} escapes {base}")
    return full


def safe_write(base: str | Path, relative_path: str, content: str) -> Path:
    """Write content to a file at base/relative_path, preventing traversal."""
    full_path = safe_path_join(base, relative_path)
    full_path.parent.mkdir(parents=True, exist_ok=True)
    full_path.write_text(content)
    return full_path


def format_artifacts(artifacts: list[Any], max_chars: int = 80_000, include_agent_header: bool = True) -> str:
    """Format a list of Artifacts into a single prompt-friendly string.

    Args:
        artifacts: List of Artifact objects (each has .agent_name, .files, .metadata).
        max_chars: Maximum total characters (truncates if exceeded).
        include_agent_header: Whether to prefix each artifact with agent/story info.

    Returns:
        Formatted string suitable for downstream agent prompts.
    """
    parts = []
    total_len = 0
    for art in artifacts:
        if isinstance(art, Exception):
            snippet = f"[Error] {art}"
            parts.append(snippet)
            total_len += len(snippet)
            continue

        if include_agent_header:
            story_id = art.metadata.get("user_story_id", "N/A")
            header = f"=== Agent: {art.agent_name} | Story: {story_id} ==="
            if total_len + len(header) > max_chars:
                parts.append("... (truncated)")
                break
            parts.append(header)
            total_len += len(header)

        for path, content in art.files.items():
            snippet = f"--- {path} ---\n{content}"
            if total_len + len(snippet) > max_chars:
                remaining = max_chars - total_len
                snippet = snippet[:remaining] + "\n... (truncated)"
            parts.append(snippet)
            total_len += len(snippet)
            if total_len >= max_chars:
                break
        if total_len >= max_chars:
            parts.append("... (artifact output truncated, review continues on remaining items)")
            break
    return "\n\n".join(parts)
