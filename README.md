# OpenClaw — Multi-Agent SDLC Ecosystem

> **Version:** 0.1.0 | **Python:** 3.11+ | **License:** MIT

OpenClaw is a **multi-agent software development lifecycle (SDLC) ecosystem** that orchestrates autonomous AI agents to go from raw requirements to production-ready code. It supports three agent runtime layers — Claude Code plugins, opencode agents, and pydantic_ai Python agents — all unified by a capability-based registry and exposed via a Model Context Protocol (MCP) server.

---

## 🌟 Key Features

- **13 Core SDLC Agents** — Business Analyst, CTO, Backend Engineer, Frontend Engineer, Database Engineer, DevOps Engineer, SRE, Security Engineer, Test Engineer, Code Reviewer, Quality Gate, UX Designer, and Documentation Writer
- **9 Domain Expert Agents** — Weather, Accountant, Market Shark, Crypto Oracle, Holiday Planner, Price Analyst, Region Analyzer, Current Events, Asymmetric Reviewer
- **Multi-Runtime Support** — Works with Claude Code, opencode, and any MCP-compatible host
- **Autonomous Remediation Loop** — Self-healing pipeline that retries with context when gates fail (up to 3 retries)
- **Capability-Based Registry** — Query agents by capability (`backend`, `security`, `review`, etc.) instead of by name
- **Vector-Indexed Knowledge Base** — pgvector-backed semantic search across ADRs, conventions, architecture decisions, and project context
- **Cross-Runtime Memory Bridge** — Bidirectional sync between OpenClaw (pgvector), Claude Code (agent-memory), and Antigravity (implicit memory)
- **Full Observability** — Logfire instrumentation for every LLM call, tool execution, and agent run with token usage tracking
- **Async Event Broker** — PostgreSQL-backed persistent event broker for long-running task handoffs

---

## 📁 Multi-Provider Structure

This repo is the **central configuration hub** for all AI agent providers in the ecosystem.
Provider configs live here; each provider gets a thin workspace under `programming/ai/<provider>/`
with symlinks back to shared templates and agent definitions.

### Config Layout

```
programming/ai/
├── agents/                          ← This repo: pydantic_ai runtime + provider configs
│   ├── src/openclaw/agents/         ← Python agent implementations
│   ├── agents/*.md                  → symlinks → shared/agents/ (role definitions)
│   ├── .claude/rules/*.md           → Claude Code project rules
│   ├── .claude/settings.local.json  → Claude Code permission config
│   ├── .claude-plugin/plugin.json   → Claude Code plugin manifest
│   ├── opencode.json                → OpenCode project/agent config
│   ├── .opencode/agents/*.md        → OpenCode subagent definitions
│   ├── .agents/workflows/*.md       → OpenClaw agent workflows
│   ├── .pre-commit-config.yaml      → Git hooks (ruff, mypy, linting)
│   └── AGENTS.md → shared/workspace/
│
├── openclaw/                       ← OpenClaw workspaces (thin wrappers)
│   ├── GUIDELINES.md                → Global agent operations guide
│   ├── *.md                        → symlinks → shared/workspace/
│   ├── agents/*.md                 → symlinks → shared/agents/
│   ├── docs-writer/                 → Sub-workspace (shared templates)
│   └── frontend-engineer/           → Sub-workspace (shared templates)
│
├── claude/                         ← Claude Code workspace
│   ├── *.md                        → symlinks → shared/workspace/
│   └── agents/*.md                 → symlinks → shared/agents/
│
├── opencode/                       ← OpenCode workspace
│   ├── *.md                        → symlinks → shared/workspace/
│   └── agents/*.md                 → symlinks → shared/agents/
│
├── antigravity/                    ← Antigravity workspace
│   ├── *.md                        → symlinks → shared/workspace/
│   └── agents/*.md                 → symlinks → shared/agents/
│
├── hermes/                         ← Hermes workspace
│   ├── *.md                        → symlinks → shared/workspace/
│   └── agents/*.md                 → symlinks → shared/agents/
│
├── shared/
│   ├── agents/*.md                 → 14 canonical agent role definitions
│   ├── workspace/*.md              → 7 workspace template files
│   ├── standards/go-standards.md   → Go coding standards
│   └── docs/provider-config.md     → Full provider config reference
```

### Provider Config Discovery

| Provider | Config Files | Discovery Mechanism |
|----------|-------------|-------------------|
| **OpenCode** | `opencode.json`, `.opencode/agents/*.md` | Auto-detected from project root when running `opencode` in `programming/ai/opencode/` |
| **Claude Code** | `.claude/rules/*.md`, `.claude/settings.local.json`, `.claude-plugin/plugin.json` | Auto-detected from `.claude/` in current working directory |
| **OpenClaw** | `.agents/workflows/*.md` | Discovered from agent workspace root |
| **Antigravity** | `.aivory/`, `.antigravitycli/` | CLI reads from project root |
| **Hermes** | `.hermes/plans/` (future) | Discovered from workspace root |

> **Full provider config reference**: [`shared/docs/provider-config.md`](../shared/docs/provider-config.md)

### The Golden Rule

**Edit agent role files in `shared/agents/`**, not in individual provider directories.
Changes propagate automatically via symlinks to all providers.

**Provider-specific configs stay in this repo** under their respective dot-directories
(`.claude/`, `.opencode/`, `.agents/`).

---

## 🏗️ Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                        AI Hosts                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌─────────────────────┐    │
│  │  Claude Code  │  │   Opencode   │  │  Antigravity / etc  │    │
│  └──────┬───────┘  └──────┬───────┘  └──────────┬──────────┘    │
│         │                 │                     │               │
│         └─────────────────┼─────────────────────┘               │
│                           │ MCP Protocol                        │
├───────────────────────────┼──────────────────────────────────────┤
│                    OpenClaw MCP Server                           │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Agent Registry (capability-based)                       │   │
│  │  ┌─────┐ ┌──────┐ ┌───────┐ ┌─────┐ ┌─────┐ ┌─────┐    │   │
│  │  │ BA  │ │ CTO  │ │Backend│ │Front│ │ DB  │ │ ... │    │   │
│  │  └─────┘ └──────┘ └───────┘ └─────┘ └─────┘ └─────┘    │   │
│  └──────────────────────────────────────────────────────────┘   │
│                           │                                      │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Infrastructure Layer                                    │   │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐   │   │
│  │  │ pgvector │ │ Logfire  │ │  Redis   │ │ JSONL    │   │   │
│  │  │ (Memory) │ │ (Traces) │ │ (Cache)  │ │ (Logs)   │   │   │
│  │  └──────────┘ └──────────┘ └──────────┘ └──────────┘   │   │
│  └──────────────────────────────────────────────────────────┘   │
│                           │                                      │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Pipeline Orchestrator (BA → Advisory → Impl → Gate)    │   │
│  └──────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

### Component Layers

| Layer | Components | Description |
|-------|-----------|-------------|
| **AI Hosts** | Claude Code, Opencode, Antigravity | IDEs/CLI tools that connect via MCP |
| **MCP Server** | `mcp_server.py` | Dynamically exposes all agents as tools |
| **Agent Registry** | `registry.py` | Capability-based agent lookup and lazy initialization |
| **SDLC Agents** | `agents/*.py` | 13 domain-specific pydantic_ai agents |
| **Domain Agents** | `agents/non_technical/*.py` | 9 travel/finance agents |
| **Pipeline** | `pipeline/`, `stages/` | Multi-stage SDLC pipeline with retry logic |
| **Vector DB** | `vector_db.py` | pgvector-based semantic search |
| **Memory Bridge** | `memory_bridge.py` | Cross-runtime memory sync |
| **Event Broker** | `event_broker.py` | PostgreSQL-backed async task management |
| **Observability** | `observability.py`, `telemetry.py` | Logfire + JSONL telemetry |

---

## 🚀 Quick Start

### Prerequisites

- Python 3.11+
- PostgreSQL with pgvector extension (for memory/knowledge base)
- At least one LLM API key (DeepSeek, OpenAI, Anthropic, or Gemini)

### Installation

```bash
# Clone the repository
git clone <repo-url>
cd openclaw

# Create virtual environment
python3.11 -m venv .venv
source .venv/bin/activate

# Install dependencies
pip install -e .

# For development dependencies
pip install -e ".[dev]"

# Copy and edit environment variables
cp .env.example .env
```

### API Keys

API keys are managed globally in `~/.zsh/envs.zsh` — not in per-repo `.env` files.
This repo includes `.env.example` as a reference, but actual keys come from your
shell environment at runtime.

```bash
# ~/.zsh/envs.zsh (one source of truth for secrets)
export DEEPSEEK_API_KEY="***"
export ANTHROPIC_BASE_URL="https://jocham.tail...ts.net/v1"
export OPENAI_BASE_URL="https://jocham.tail...ts.net/v1"
export LOGFIRE_TOKEN="***"
export OPENCLAW_AUTH_TOKEN="***"
```

```bash
# LLM Provider (at least one required)
OPENAI_API_KEY="sk-..."
ANTHROPIC_API_KEY="sk-ant-..."
GEMINI_API_KEY="..."
DEEPSEEK_API_KEY="sk-..."

# Observability (recommended)
LOGFIRE_TOKEN="pylf_v2_eu_..."
LOGFIRE_SEND_TO_LOGFIRE=true

# Database (for pgvector knowledge base)
DATABASE_URL="postgresql://user:pass@localhost:5432/openclaw"
```

### Running the Pipeline

```bash
# Run the full SDLC pipeline
python main.py --project my-service --requirement "Build a payment processing API"

# Run a specific stage
python main.py --step ba --project my-service --requirement "Build a payment API"

# Run with dry run (mock data, no LLM calls)
python main.py --dry-run --project my-service

# Resume from last checkpoint
python main.py --resume --project my-service
```

### Connecting via MCP

#### Claude Code

```bash
# Register the MCP server
claude mcp add --scope user openclaw-agents -- \
  /bin/bash /path/to/openclaw/mcp_run.sh

# Verify connection
claude mcp get openclaw-agents
# Expected: Status: ✓ Connected
```

#### Opencode

Add to your `opencode.json`:

```json
{
  "mcpServers": {
    "agents": {
      "command": "bash",
      "args": ["/path/to/openclaw/mcp_run.sh"],
      "enabled": true
    }
  }
}
```

---

## 🤖 Agent Reference

### SDLC Pipeline Agents

| Agent | Tool Name | Capabilities | Description |
|-------|-----------|-------------|-------------|
| **Business Analyst** | `run_ba` | `ba`, `requirements` | Converts raw requirements into user stories with Gherkin acceptance criteria using DDD |
| **CTO / Architect** | `run_cto` | `cto`, `architecture`, `advisory` | Pre-implementation architecture reviews, ADR enforcement, and hard constraint validation |
| **Backend Engineer** | `run_backend` | `backend`, `implementation` | Go (1.26+) Hexagonal Architecture, gRPC, NATS/Kafka, OpenTelemetry |
| **Frontend Engineer** | `run_frontend` | `frontend`, `implementation` | Vue 3 Composition API, TSX, real-time event bus UI |
| **Database Engineer** | `run_database` | `database`, `db_schema`, `migrations` | PostgreSQL migrations, indexing strategies, Redis caching |
| **DevOps Engineer** | `run_devops` | `devops`, `ci_cd`, `deployment` | CI/CD pipelines, Docker Compose, Makefiles |
| **SRE Engineer** | `run_sre` | `sre`, `infrastructure` | Terraform/OpenTofu, Crossplane, GitOps, multi-region K8s |
| **Security Engineer** | `run_security` | `security`, `audit` | OWASP Top 10 audits, secret scanning, structured findings |
| **Test Engineer** | `run_test_eng` | `test`, `testing` | Table-driven Go tests, BDD Playwright from Gherkin |
| **Test Generator** | `run_test_gen` | `test_gen`, `test_generation` | Automatic test generation |
| **Go Test Runner** | `run_go_test` | `go_test`, `go_testing` | Test execution and debugging |
| **Code Reviewer** | `run_review` | `review`, `code_review` | Production readiness verification, drift detection, risk ranking |
| **Quality Gate** | `run_quality_gate` | `quality_gate`, `review` | Complexity scoring, over-engineering detection |
| **UX Designer** | `run_ux` | `ux`, `design` | WCAG 2.1 AA accessibility and UX reviews |
| **Docs Writer** | `run_docs` | `docs`, `documentation` | OpenAPI specs, runbooks, README generation |
| **Service Engineer** | `run_service_engineer` | `service_engineer`, `existing_code`, `implementation` | Surgical modifications to existing Go codebases |
| **Planner** | `run_planner` | `plan`, `planning` | Goal decomposition into step-by-step execution plans |

### Domain Expert Agents (Travel & Finance)

| Agent | Tool Name | Capabilities | Description |
|-------|-----------|-------------|-------------|
| **Holiday Planner** | `run_holiday_planner` | `planning`, `travel` | Itinerary organization and travel coordination |
| **Region Analyzer** | `run_region_analyzer` | `analysis` | Cost of living, safety, and geographical analysis |
| **Asymmetric Reviewer** | `run_asymmetric_reviewer` | `legal`, `finance` | Corporate/legal travel savings and loophole identification |
| **Current Events** | `run_current_events` | `news`, `history` | Modern news blended with historical context |
| **Weather** | `run_weather` | `weather` | Forecasts and climate summaries |
| **Accountant** | `run_accountant` | `finance` | Budget management and expense calculation |
| **Market Shark** | `run_market_shark` | `finance`, `crypto`, `stocks`, `investing` | Stock market and investment analysis |
| **Crypto Oracle** | `run_crypto_oracle` | `finance`, `news`, `research` | Cryptocurrency market analysis |
| **Price Analyst** | `run_price_analyst` | `pricing`, `analysis`, `purchasing` | Pricing comparison and analysis |

---

## 🔧 API Reference

### MCP Tools

All agents are exposed as MCP tools with the prefix `run_`. Full API reference is available in [docs/API_REFERENCE.md](docs/API_REFERENCE.md).

**Core orchestration tools:**

| Tool | Description |
|------|-------------|
| `delegate_to_openclaw_agent(capability, context, task)` | Delegate a task to any agent by capability |
| `list_openclaw_capabilities()` | List all registered capabilities |
| `run_openclaw_pipeline(project_name, requirement)` | Run the full SDLC pipeline as a background task |
| `check_pipeline_status(run_id)` | Poll pipeline status |
| `plan_and_execute(goal)` | Plan and execute a high-level goal |
| `modify_existing_code(change_description, codebase_path)` | Modify existing Go code with autonomous remediation |
| `scaffold_and_build_service(service_name, bounded_context)` | Build a new service from scratch |

**Knowledge management tools:**

| Tool | Description |
|------|-------------|
| `search_adrs(query)` | Search Architecture Decision Records |
| `save_adr(decision_id, content)` | Save a new ADR |
| `seed_project_context(project_path)` | Index project files into vector DB |
| `query_context(query, domain, top_k)` | Query the vector knowledge base |

**Async task tools:**

| Tool | Description |
|------|-------------|
| `submit_async_task(task_type, payload)` | Submit a long-running task |
| `check_task_status(task_id)` | Check async task status |
| `wait_for_task(task_id, timeout)` | Wait for task completion |

**Memory bridge tools:**

| Tool | Description |
|------|-------------|
| `sync_memory(all_runtimes, max_entries)` | Sync memory across runtimes |
| `memory_bridge_status()` | Get memory system health |

### CLI Pipeline

```bash
python main.py --step <step> --project <name> [options]
```

Available steps: `ba`, `advisory`, `implementation`, `backend`, `frontend`, `database`, `test`, `devops`, `docs`, `quality_gate`, `sre`, `review`, `security`, `all`

---

## 🔄 Pipeline Flow

### Full SDLC Pipeline

```
Raw Requirements
      │
      ▼
┌──────────────┐
│  BA Stage    │  → User Stories with Gherkin + Event Triggers
└──────┬───────┘
       │
       ▼
┌──────────────┐
│ Advisory     │  → CTO Architecture Review
└──────┬───────┘
       │
       ▼
┌────────────────────────────────────────────────┐
│ Implementation Stage                           │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐       │
│  │ Backend  │ │ Frontend │ │ Database │       │
│  └──────────┘ └──────────┘ └──────────┘       │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐       │
│  │  DevOps  │ │   Docs   │ │   SRE    │       │
│  └──────────┘ └──────────┘ └──────────┘       │
│  ┌──────────┐                                  │
│  │   Test   │  → If fails → Retry impl        │
│  └──────────┘                                  │
└──────────────────────┬─────────────────────────┘
                       │
                       ▼
┌────────────────────────────────────────────────┐
│ Quality Gate Stage (Parallel)                  │
│  ┌──────────────┐   ┌──────────────┐          │
│  │ Quality Gate │   │    Review    │          │
│  │ (Complexity) │   │ (Correctness)│          │
│  └──────────────┘   └──────────────┘          │
│  ┌──────────────┐   ┌──────────────┐          │
│  │   Security   │   │     SRE      │          │
│  └──────────────┘   └──────────────┘          │
└──────────────────────┬─────────────────────────┘
                       │
                       ▼
              ✅ Approved Artifacts
```

### Existing Code Modification Pipeline (Autonomous Remediation)

```
Change Description
      │
      ▼
┌─────────────────────┐
│  Service Engineer   │  → Reads files, applies change
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   Test Engineer     │  → Generates/updates tests
└──────────┬──────────┘
           │
           ▼
┌─────────────────────────────────────┐
│  Parallel Verification Gates        │
│  ┌──────────────┐ ┌──────────────┐  │
│  │ Quality Gate │ │ Code Review  │  │
│  │(Deterministic)│ │ (Heuristic)  │  │
│  └──────────────┘ └──────────────┘  │
└──────────┬──────────────────────────┘
           │
     ┌─────┴─────┐
     ▼           ▼
  ✅ Pass     ❌ Fail (up to 3 retries)
                 │
                 ▼
          ┌─────────────────┐
          │ Auto-Remediation│  → Service Engineer with error context
          └─────────────────┘
```

---

## 🧪 Testing

```bash
# Run all tests
pytest

# Run unit tests only
pytest -m unit

# Run integration tests
pytest -m integration

# Run with coverage
pytest --cov=openclaw --cov-report=html
```

---

## 📁 Project Structure

```
openclaw/
├── agents/*.md                    → symlinks → shared/agents/ (role definitions)
├── .opencode/agents/*.md          # OpenCode subagent definitions
├── .opencode/package.json          # OpenCode SDK dependency
├── opencode.json                   # OpenCode project & agent configuration
├── .claude-plugin/plugin.json     # Claude Code plugin manifest
├── .claude/rules/*.md             # Claude Code project rules (auto-triggered)
├── .claude/settings.local.json    # Claude Code MCP permission config
├── .agents/workflows/*.md         # OpenClaw multi-agent workflows
├── .pre-commit-config.yaml        # Git hooks (ruff, mypy, linting)
├── src/
│   └── openclaw/
│       ├── agents/                # pydantic_ai agent implementations
│       │   ├── ba.py              # Business Analyst
│       │   ├── backend.py         # Backend Engineer (Go)
│       │   ├── frontend.py        # Frontend Engineer (Vue 3)
│       │   ├── database.py        # Database Engineer
│       │   ├── devops.py          # DevOps Engineer
│       │   ├── docs.py            # Documentation Writer
│       │   ├── sre.py             # SRE Engineer
│       │   ├── security.py        # Security Engineer
│       │   ├── test_eng.py        # Test Engineer
│       │   ├── review.py          # Code Reviewer
│       │   ├── quality_gate.py    # Quality Gate
│       │   ├── ux.py              # UX Designer
│       │   ├── cto.py             # CTO/Architect
│       │   ├── planner_agent.py   # Goal Planner
│       │   ├── service_engineer.py # Existing Code Modifier
│       │   ├── registration.py    # Centralized agent registration
│       │   └── non_technical/     # Travel & Finance agents
│       ├── tools/                 # Shared agent tools
│       │   ├── a2a_tools.py       # Agent-to-agent delegation
│       │   ├── search.py          # Codebase search tools
│       │   ├── market_tools.py    # Stock/crypto data tools
│       │   ├── fs_tools.py        # Filesystem tools
│       │   ├── web_fetch.py       # Web fetching tools
│       │   ├── docs.py            # Documentation tools
│       │   ├── registry.py        # Tool registry
│       │   └── ...
│       ├── models/                # Pydantic output models
│       │   ├── core.py            # Core data models
│       │   └── factory.py         # Model factory (multi-provider)
│       ├── pipeline/              # Pipeline configuration
│       │   ├── config.py          # PipelineConfig
│       │   └── orchestrator.py    # OpenClawPipeline
│       ├── stages/                # Pipeline stages
│       │   ├── base.py            # StageRunner base class
│       │   ├── ba_stage.py        # BA pipeline stage
│       │   ├── advisory_stage.py  # CTO advisory stage
│       │   ├── implementation_stage.py  # Implementation stage
│       │   └── quality_gate_stage.py    # Quality gate stage
│       ├── mcp_server.py          # MCP server entry point
│       ├── registry.py            # AgentRegistry
│       ├── context_engine.py      # Vector-indexed context retrieval
│       ├── vector_db.py           # pgvector database interface
│       ├── memory_bridge.py       # Cross-runtime memory sync
│       ├── event_broker.py        # PostgreSQL async event broker
│       ├── existing_code_handler.py  # Existing code pipeline
│       ├── pipeline_jobs.py      # Background pipeline runner
│       ├── settings.py            # pydantic-settings configuration
│       ├── observability.py       # Logfire setup
│       ├── telemetry.py           # JSONL telemetry
│       ├── healthcheck.py         # Startup validation
│       └── exceptions.py          # Typed exception hierarchy
├── main.py                        # CLI entry point
├── start_mcp.py                   # MCP server launcher
├── pyproject.toml                 # Project configuration
├── .env.example                   # Environment template
└── tests/                         # pytest test suite
```

---

## 📊 Observability

All agent runs, tool calls, and pipeline stages are instrumented with **Logfire**:

```bash
# Every agent.run() produces a span with:
# - Token usage (input/output tokens)
# - Call latency
# - Model name
# - Input/output structures
# - Error traces

# View the dashboard at:
# https://logfire.pydantic.dev/[your-project]
```

JSONL telemetry is also written to `telemetry.jsonl` in the project root.

```bash
# Clear cached data
./scripts/clear_cache.sh
```

---

## 🔐 Security

- **Path traversal protection**: All file operations in `service_engineer` and `utils.py` are sandboxed and prevent directory traversal
- **DNS rebinding protection**: MCP server has built-in transport security
- **Secret scanning**: Security agent uses `secrets.py` tools to detect hardcoded credentials
- **Sandboxed execution**: File reads/writes are constrained to the project root
- **API key validation**: Startup checks validate that API keys are not placeholder values

---

## 🤝 Contributing

Please see [CONTRIBUTING.md](CONTRIBUTING.md) for detailed contribution guidelines.

**Development setup:**

```bash
pip install -e ".[dev]"
pre-commit install    # Install git hooks
ruff check .          # Lint
mypy src/openclaw     # Type check
pytest                # Test
```

---

## 📚 Additional Documentation

| Document | Description |
|----------|-------------|
| [API Reference](docs/API_REFERENCE.md) | Complete MCP tool and CLI API reference |
| [OpenAPI Spec](docs/openapi/openclaw-api.yaml) | OpenAPI 3.1 specification for the MCP API |
| [Provider Config Reference](../shared/docs/provider-config.md) | How providers discover configs in this repo |
| [Go Standards](CODING_STANDARDS.md) | Go coding standards for generated code |
| [AGENTS.md](AGENTS.md) | Agent system prompts and definitions |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Contribution guidelines |
| Agent Role Files | `agents/*.md` → symlinks → `shared/agents/` |
| OpenCode Agents | `.opencode/agents/*.md` — OpenCode subagent definitions |
| Claude Rules | `.claude/rules/*.md` — Claude Code auto-triggered rules |

---

## 🛠️ Environment Variables Reference

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `OPENAI_API_KEY` | No* | — | OpenAI API key |
| `ANTHROPIC_BASE_URL` | No | — | Anthropic API proxy base URL (Aperture) |
| `OPENAI_BASE_URL` | No | — | OpenAI API proxy base URL (Aperture) |
| `OPENCLAW_AUTH_TOKEN` | No | — | OpenClaw gateway auth token |
| `DEEPSEEK_API_KEY` | No* | — | DeepSeek API key |
| `LOGFIRE_TOKEN` | No | — | Logfire observability token |
| `DATABASE_URL` | Yes | `postgresql://localhost:5432/openclaw` | PostgreSQL connection string |
| `REDIS_IRIS_URL` | No | — | Redis Iris connection URL |
| `model_provider` | No | `deepseek` | LLM provider override |

*\*At least one API key must be configured*

---

## 📝 License

MIT License — see [LICENSE](LICENSE) for details.
