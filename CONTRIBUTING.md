# Contributing to OpenClaw

Thank you for your interest in contributing to the openclaw agent ecosystem! This guide will help you understand how to add new agents, tools, and run the pipeline locally.

## Project Structure

OpenClaw is divided into three main layers:

1. **Claude Code plugin** (`agents/*.md`, `.claude-plugin/`) - System prompts and definitions.
2. **Opencode Agents** (`.opencode/agents/`) - Primary and subagent definitions.
3. **Pydantic AI Agents** (`src/openclaw/agents/`) - The runtime implementation of the agents, providing structured outputs and MCP exposure.

## Adding a New Agent

To add a new agent to the ecosystem, you must update multiple layers:

### 1. Pydantic AI Implementation

Create a new Python file in `src/openclaw/agents/` (e.g., `my_agent.py`):

```python
from pydantic_ai import Agent, RunContext
from ..models import MyCustomOutputModel

my_agent = Agent(
    model='claude-3-5-sonnet-latest',
    result_type=MyCustomOutputModel,
    system_prompt="You are a specialized agent for...",
)

@my_agent.tool
def my_custom_tool(ctx: RunContext, param: str) -> str:
    """Tool description goes here."""
    return f"Processed {param}"
```

Then, register your agent in `src/openclaw/agents/registration.py` so it is discoverable by the MCP server and pipeline runner.

### 2. Claude Code Plugin Definition

Add an agent specification markdown file in `agents/my-agent.md`:

```markdown
# My Agent

**Role**: specialized role description
**When to use**: Under these specific circumstances...

<instructions>
1. Step 1
2. Step 2
</instructions>
```

Make sure to update the `README.md` tables to include your new agent.

## Local Development & Testing

1. **Virtual Environment**: Ensure you are using the correct virtual environment (e.g., `.venv` or `.venv_313`).
2. **Run Pipeline**: You can test the main pipeline via the CLI:
   ```bash
   python main.py --project test-project --requirement "Test requirement"
   ```
3. **Tests**: Use the existing test suites in the `tests/` directory to ensure your agents produce the expected outputs and behavior.

## Observability & Debugging

All LLM calls are instrumented with Logfire. Make sure you have your `LOGFIRE_TOKEN` set. You can view telemetry traces at `https://logfire-eu.pydantic.dev/drew/argus`.

If you experience caching issues during development, run:
```bash
./scripts/clear_cache.sh
```

## Coding Standards

Before opening a pull request, ensure all generated or manually written Go code adheres to the [CODING_STANDARDS.md](CODING_STANDARDS.md). All Python code should be typed and pass formatting/linting checks.
