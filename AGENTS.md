# AGENTS.md — OpenClaw Multi-Agent SDLC Ecosystem

## What This Repo Is

A three-layer multi-agent SDLC ecosystem:

1. **Claude Code plugin** (`agents/*.md`, `.claude-plugin/`) — 14 SDLC agent system prompts + Travel/Finance domain agents
2. **OpenCode agents** (`.opencode/agents/`, `opencode.json`) — primary/subagent definitions for existing code modification
3. **pydantic_ai Python agents** (`src/openclaw/agents/`) — runtime agents with structured outputs, tools, MCP exposure

## Directory Structure

```
agents/*.md                  # Claude Code agent definitions (detailed system prompts)
.opencode/agents/*.md        # OpenCode primary + subagent definitions
.claude-plugin/plugin.json   # Claude Code plugin manifest
.claude/rules/*.md           # Claude Code rules (auto-triggered on keywords)
src/openclaw/                # Python pydantic_ai runtime
  agents/                    # Agent implementations (pydantic_ai Agents)
  agents/non_technical/      # Finance/travel agents
  tools/                     # Shared tools (market data, A2A delegation)
  models/                    # Pydantic output models + model factory
  mcp_server.py              # MCP server exposing agents as tools
  registry.py                # Capability-based agent registry
  settings.py                # pydantic-settings configuration
  existing_code_handler.py   # Pipeline orchestrator for existing code mods
main.py                      # CLI pipeline entry point
start_mcp.py                 # MCP server launcher (production)
tests/                       # pytest test suite
CODING_STANDARDS.md          # Go coding standards (for generated code)
```

## Python Conventions

- **Python version**: 3.11+ (project requires >=3.11)
- **Virtual env**: `.venv_313` (Python 3.13)
- **Formatter**: ruff (line length 120, double quotes)
- **Linter**: ruff + mypy (pre-commit hooks)
- **Type hints**: encouraged but not enforced (`disallow_untyped_defs=false`)
- **Imports**: ruff I-rule organises; no manual sorting needed
- **Settings**: use `from openclaw.settings import settings` — pydantic-settings, env-loaded
- **Models**: use `from openclaw.models.factory import create_model` for LLM model construction
- **Output types**: pydantic BaseModel subclasses from `openclaw.models.core`
- **Logging**: standard `logging.getLogger(__name__)` + logfire for telemetry

## Development Commands

```bash
# Activate venv
source .venv_313/bin/activate

# Install dev deps
pip install -e ".[dev]"

# Run tests
pytest tests/ -v

# Lint
ruff check src/
ruff format --check src/

# Type check
mypy src/openclaw

# Run pre-commit
pre-commit run --all-files

# Run pipeline (CLI)
python main.py --project test-project --requirement "Build a test service"

# Run pipeline (dry run, no LLM calls)
python main.py --project test-project --dry-run

# Start MCP server
python start_mcp.py

# Clear cache
./scripts/clear_cache.sh
```

## Agent Architecture

### Three Layers, One Purpose

| Layer | Location | Format | Used By |
|-------|----------|--------|---------|
| System prompts | `agents/*.md` | Markdown with YAML frontmatter | Claude Code, OpenCode |
| Subagent config | `opencode.json`, `.opencode/agents/` | JSON / Markdown | OpenCode |
| Runtime agents | `src/openclaw/agents/*.py` | pydantic_ai Agent | MCP server, CLI pipeline |

### Adding a New Agent

1. **System prompt**: Create `agents/my-agent.md` with YAML frontmatter (name, description, tools, model)
2. **pydantic_ai agent**: Create `src/openclaw/agents/my_agent.py` with Agent + output type + tools
3. **Registration**: Add to `src/openclaw/agents/registration.py` in `register_all_agents()`
4. **MCP exposure** (optional): Add MCP tool in `src/openclaw/mcp_server.py`
5. **OpenCode config** (optional): Add to `opencode.json` or `.opencode/agents/`
6. **README table**: Update the agent tables

### Model Configuration

Per-agent models are configured in `settings.py` (e.g., `ba_model`, `backend_model`).
The `model_provider` setting can globally override to a single provider (e.g., `deepseek`)
but defaults to `None` (use per-agent assignments).

To force all agents to use DeepSeek for development:
```bash
export MODEL_PROVIDER=deepseek
```

## MCP Server

The MCP server (`start_mcp.py`) exposes:
- `delegate_to_openclaw_agent` — capability-based agent routing
- `modify_existing_code` — service_engineer → test → quality_gate → review pipeline
- `run_openclaw_pipeline` — full BA → Advisory → Implementation → Review pipeline
- `scaffold_and_build_service` — new service scaffolding
- `plan_and_execute` — planner → executor with dependency ordering
- `run_*` — individual travel/finance agents (weather, accountant, etc.)
- `search_adrs` / `save_adr` — ADR knowledge base

## Key Rules for AI Agents Working in This Repo

1. **Python project, not Go**: The repo itself is Python. CODING_STANDARDS.md applies to GENERATED Go code, not this codebase.
2. **Use ruff for linting**: `ruff check src/` and `ruff format --check src/`
3. **Use pytest for tests**: `pytest tests/ -v` — asyncio_mode=auto is configured
4. **Agent files are markdown**: Changes to `agents/*.md` are prompt engineering; test them by running the relevant agent
5. **The registry is lazy**: `register_all_agents()` must be called before `registry.get()` or `registry.query()`
6. **Do not edit generated code**: `generated-app/` is pipeline output, not source
7. **Logfire for observability**: Set `LOGFIRE_TOKEN` to enable. Traces at https://logfire-eu.pydantic.dev/drew/argus
