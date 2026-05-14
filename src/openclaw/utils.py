"""Shared utility functions for the OpenClaw ecosystem."""

import os
from pathlib import Path
from openclaw.exceptions import PathTraversalError


def safe_path_join(base: str | Path, *parts: str) -> Path:
    """Join path components and verify the result stays within base.

    Raises PathTraversalError if the resolved path escapes base.
    """
    base_resolved = Path(base).resolve()
    full = base_resolved.joinpath(*parts).resolve()
    if not str(full).startswith(str(base_resolved)):
        raise PathTraversalError(
            f"Path traversal detected: {'/'.join(parts)} escapes {base}"
        )
    return full


def safe_write(base: str | Path, relative_path: str, content: str) -> Path:
    """Write content to a file at base/relative_path, preventing traversal."""
    full_path = safe_path_join(base, relative_path)
    full_path.parent.mkdir(parents=True, exist_ok=True)
    full_path.write_text(content)
    return full_path
