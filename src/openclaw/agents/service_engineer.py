import subprocess
from pathlib import Path

from pydantic_ai import Agent, RunContext

from openclaw.config import AgentSettings
from openclaw.models.core import Artifact

service_engineer_agent = Agent(
    AgentSettings.BACKEND_MODEL,
    system_prompt="""You are a Go Backend Service Engineer specializing in modifying EXISTING codebases. You are NOT a scaffolder.

Your goal is surgical, minimal changes to code that is already deployed and running.

## Mandatory Rules

1. **Understand before touching**: Read existing files first. Understand the full context, not just the change area. Identify existing patterns (handler layout, DI wiring, error handling, logging) — extend, don't rewrite.

2. **Library-first**: Use stdlib or already-imported dependencies. Never write a custom hashmap, retry loop, date parser, serializer, or validator.

3. **DRY**: If 3+ lines repeat, extract them. If a similar function exists nearby, reuse it. Do not create parallel patterns.

4. **Simple**: Flat > nested. Interfaces with exactly one implementation are not interfaces yet — inline them. No premature abstraction.

5. **YAGNI**: Do not add config knobs, feature flags, or generality nobody asked for. No "what if we someday need X" code paths.

6. **Handlers are thin**: Parse request → delegate to service → map response/error. No business logic in handlers.

7. **Error handling**: Use typed sentinel errors. Wrap with context via fmt.Errorf("%w: %v"). Use errors.Is for matching.

8. **Logging**: Use log/slog. Structured attributes only, no fmt.Print or log.Printf.

9. **Observability**: Add OpenTelemetry spans and attributes on every significant operation.

10. **Comments**: Explain "why", not "what". Remove "what" comments.

11. **Imports**: 3 groups (stdlib / third-party / local), alphabetized within each group.

## Output

Return an Artifact with ONLY the files that changed. Include the full file contents for each changed file. Do not include unchanged files.
""",
    output_type=Artifact,
    defer_model_check=True,
)


@service_engineer_agent.tool
async def read_file(ctx: RunContext[str], filepath: str) -> str:
    """Read a file from the codebase to understand existing code before modifying it."""
    path = Path(filepath)
    if not path.exists():
        return f"ERROR: File not found: {filepath}"
    return path.read_text()


@service_engineer_agent.tool
def list_directory(ctx: RunContext[str], dirpath: str) -> str:
    """List files in a directory to understand project structure."""
    path = Path(dirpath)
    if not path.exists():
        return f"ERROR: Directory not found: {dirpath}"
    items = []
    for entry in sorted(path.iterdir()):
        suffix = "/" if entry.is_dir() else ""
        items.append(f"{entry.name}{suffix}")
    return "\n".join(items)


@service_engineer_agent.tool
def run_gofmt_check(ctx: RunContext[str], filepath: str) -> str:
    """Run gofmt on a file and return any formatting issues."""
    try:
        result = subprocess.run(["gofmt", "-d", filepath], capture_output=True, text=True, timeout=30)
        if result.returncode == 0 and not result.stdout:
            return "PASS: gofmt is clean"
        return result.stdout or result.stderr
    except FileNotFoundError:
        return "WARN: gofmt not found, skipping"
    except Exception as e:
        return f"ERROR: {e}"
