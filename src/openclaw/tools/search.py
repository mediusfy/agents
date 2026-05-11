import asyncio
import os
import re
import glob as pyglob
from pydantic_ai import RunContext
from openclaw.tools.registry import register_tool

async def search_codebase(ctx: RunContext[str], pattern: str, path: str = ".", include: str = "*.go") -> list[str]:
    try:
        proc = await asyncio.create_subprocess_exec(
            "rg", "-l", "--glob", include, pattern, path,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await proc.communicate()
        if proc.returncode == 0:
            return stdout.decode().strip().splitlines()
        elif proc.returncode == 1:
            return []
        else:
            return [f"rg error: {stderr.decode().strip()}"]
    except FileNotFoundError:
        return ["ripgrep (rg) not installed - consider installing it or use search_pattern_in_content"]
    except Exception as e:
        return [f"Search failed: {e}"]

async def search_pattern_in_content(ctx: RunContext[str], pattern: str, content: str) -> list[dict]:
    results = []
    for i, line in enumerate(content.splitlines(), 1):
        if re.search(pattern, line):
            results.append({"line": i, "content": line.strip()})
    return results

async def search_files(ctx: RunContext[str], glob: str) -> list[str]:
    return pyglob.glob(glob, recursive=True)

register_tool("search_codebase", search_codebase,
              "Search the codebase for a text pattern using ripgrep", ["search", "security", "code_review"])
register_tool("search_pattern_in_content", search_pattern_in_content,
              "Search a string for regex pattern, returns line matches", ["search", "security"])
register_tool("search_files", search_files,
              "Search the filesystem using a glob pattern", ["search", "code_review"])
