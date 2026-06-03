import glob
import os

from openclaw.tools.registry import register_tool


def read_file(filepath: str) -> str:
    """Read the contents of a file from the repository. Useful for reusing existing code."""
    try:
        with open(filepath) as f:
            return f.read()
    except Exception as e:
        return f"Error reading file: {e}"


def list_dir(directory: str = ".") -> str:
    """List all files in the given directory. Useful for exploring the repository."""
    try:
        return "\n".join(os.listdir(directory))
    except Exception as e:
        return f"Error listing directory: {e}"


def search_files(pattern: str) -> str:
    """Search for files matching a glob pattern (e.g. '**/*.go')."""
    try:
        matches = glob.glob(pattern, recursive=True)
        return "\n".join(matches) if matches else "No files found."
    except Exception as e:
        return f"Error searching files: {e}"


register_tool(
    "read_file",
    read_file,
    "Read the contents of a file from the repository. Useful for understanding existing codebase or finding reusable utilities.",
    ["backend", "frontend", "test_eng", "implementation", "docs", "devops", "sre", "database"],
)

register_tool(
    "list_dir",
    list_dir,
    "List all files in the given directory. Useful for exploring the repository layout.",
    ["backend", "frontend", "test_eng", "implementation", "docs", "devops", "sre", "database"],
)

register_tool(
    "search_files",
    search_files,
    "Search for files matching a glob pattern (e.g. '**/*.go' or 'src/components/*.vue').",
    ["backend", "frontend", "test_eng", "implementation", "docs", "devops", "sre", "database"],
)
