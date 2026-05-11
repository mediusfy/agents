import os
from pydantic_ai import RunContext
from openclaw.tools.registry import register_tool

async def update_documentation(ctx: RunContext[any], file_path: str, content: str, mode: str = "append") -> str:
    """Updates project documentation. Use this to proactively document decisions or implementation details."""
    base_docs_dir = "docs"
    full_path = os.path.join(base_docs_dir, file_path)
    
    # Ensure directory exists
    os.makedirs(os.path.dirname(full_path), exist_ok=True)
    
    if mode == "overwrite":
        with open(full_path, "w") as f:
            f.write(content)
    else:
        with open(full_path, "a") as f:
            f.write(f"\n\n{content}")
            
    return f"Documentation updated: {file_path}"

register_tool("update_documentation", update_documentation, "Updates project documentation", ["documentation"])
