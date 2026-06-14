# Orgitration — Multi-Agent SDLC Orchestration

## Overview

Orgitration orchestrates 25+ AI agents through LangGraph state machines to autonomously progress from raw requirements to production-ready, validated code.

### Design Tenets
- **LangGraph only** — single orchestration framework with state machines, retry loops, and subgraphs
- **pgvector memory** — PostgreSQL-backed vector similarity for context retrieval, no external dependencies
- **Multi-perspective validation** — every agent's output is peer-reviewed and quality-gated by parallel verification gates
- **Agents check each other** — peer review node in the implementation subgraph, multi-perspective QG runs 3 agents concurrently

## Architecture

```
START → BA → Advisory → HumanGate → Implementation Subgraph → Merge → END
                              ┌──────────────────────────────┐
                              │ implementation → peer_review │
                              │       ↓                     │
                              │   quality_gate (parallel:    │
                              │   security + QG + review)    │
                              │       ↓                     │
                              │   retry_or_exit ──→ (loop)   │
                              └──────────────────────────────┘
```

### Key Components

- **Pipeline** — LangGraph `StateGraph` with conditional edges, subgraphs, and PostgresSaver checkpoints
- **25+ Agents** — `pydantic_ai.Agent` with typed outputs, registered via `AgentRegistry`
- **Tools** — ~30 tools (search, build, test, deps, memory, web) assigned by category groups
- **Memory** — pgvector (`all-MiniLM-L6-v2`) for semantic retrieval + cross-runtime bridge to Claude Code / Antigravity
- **Prompts** — Centralized YAML-based prompts with `PromptManager` singleton
- **MCP Server** — Exposes 45 tools: run agents, pipeline lifecycle, context queries, memory sync

## Quick Start

```bash
# Install
uv sync

# Run pipeline from CLI
uv run python main.py --project myapp --requirement "Build a payment service"

# Start MCP server
uv run python -c "from orchestration.mcp_server import mcp; mcp.run()"

# Run tests
uv run pytest
```

## Project Structure

```
src/orchestration/
├── agents/           # 25+ pydantic_ai agent definitions
├── mcp_server/       # MCP server (agent_tools, pipeline_tools, context_tools, memory_tools)
├── pipeline/         # LangGraph pipeline (graphs, nodes, routing, saver, config)
├── stages/           # Pipeline stage implementations (BA, Advisory, Implementation, QG, Merge)
├── adapters/         # PydanticAIAgentProvider, WorkspaceContext, StateRepository
├── models/           # PipelineState, UserStory, Artifact, FailureReport
├── tools/            # Agent tools (search, build, test, memory, web, etc.)
├── prompts/          # YAML prompt files per agent
├── memory.py         # VectorMemory with pgvector backend
├── memory_bridge.py  # pgvector ↔ Claude Code ↔ Antigravity sync
├── context_engine.py # Vector-indexed context retrieval
├── registry.py       # AgentRegistry + instrumented_query
├── vector_db.py      # Async pgvector client
├── validation_gate.py# Cross-agent ValidationGate protocol + CompositeGate
├── retry.py          # Exponential backoff retry wrapper
├── prompt_manager.py # Centralized prompt loading
├── pipeline_jobs.py  # Background pipeline execution
├── pipeline_run_repo.py # PostgreSQL-backed run persistence
├── pipeline_metrics.py  # Logfire-integrated per-stage metrics
└── event_broker.py   # Async event/message broker
```

## Blueprints

| Blueprint | Stages |
|-----------|--------|
| `langgraph_full` | BA → Advisory → Implementation → Quality Gate |
| `langgraph_quick` | Implementation → Quality Gate (backend-only) |
| `new_feature` | BA → Advisory → Implementation → Quality Gate |
| `quick_backend` | Implementation → Quality Gate |
| `docs_update` | Implementation (docs agent) → Quality Gate |
| `security_review` | Quality Gate (security agent) |

## Environment

Configure via `.env` or environment variables. See `.env.example` for all options.

Key settings:
- `DATABASE_URL` — PostgreSQL connection for pgvector + pipeline state
- `LOGFIRE_TOKEN` — Logfire observability token
- `model_provider` — LLM backend (litellm, deepseek, openai, gemini)
