import os

from pydantic_ai import RunContext

from openclaw.tools.registry import register_tool
from openclaw.utils import safe_path_join


async def update_documentation(ctx: RunContext, file_path: str, content: str, mode: str = "append") -> str:
    """Updates project documentation. Use this to proactively document decisions or implementation details."""
    base_docs_dir = os.path.realpath("docs")
    try:
        full_path = safe_path_join(base_docs_dir, file_path)
    except ValueError as e:
        return f"Error: {e}"

    os.makedirs(os.path.dirname(str(full_path)), exist_ok=True)

    if mode == "overwrite":
        with open(full_path, "w") as f:
            f.write(content)
    else:
        with open(full_path, "a") as f:
            f.write(f"\n\n{content}")

    return f"Documentation updated: {file_path}"


register_tool("update_documentation", update_documentation, "Updates project documentation", ["documentation"])
