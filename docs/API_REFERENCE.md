# Orgitration API Reference

> **Version:** 0.1.0  
> **Last Updated:** 2025  
> **Service:** Multi-Agent SDLC Ecosystem

Orgitration exposes capabilities through two primary API surfaces:

1. **MCP (Model Context Protocol) Server** — exposes agents and orchestration tools as callable tools for AI hosts (Claude Code, Antigravity, etc.)
2. **CLI Pipeline** — command-line entry point for running the full SDLC pipeline

---

## Table of Contents

- [MCP Server API](#mcp-server-api)
  - [Agent Execution Tools](#agent-execution-tools)
  - [Orchestration Tools](#orchestration-tools)
  - [Knowledge Management Tools](#knowledge-management-tools)
  - [Async Task Tools](#async-task-tools)
  - [Memory Bridge Tools](#memory-bridge-tools)
- [CLI Pipeline API](#cli-pipeline-api)
- [Capability-Based Agent Registry](#capability-based-agent-registry)
- [Data Models](#data-models)
- [Configuration Reference](#configuration-reference)
- [Error Handling](#error-handling)

---

## MCP Server API

The MCP server (`mcp_server.py`) registers all agents as individual tools and provides orchestration, knowledge management, and utility tools. All tools are available over the MCP transport and can be discovered via `mcp.tool()` decorators.

### Agent Execution Tools

Each registered agent is automatically exposed as an MCP tool named `run_{agent_name}`. These accept a single prompt string and return the agent's response.

#### `run_ba(request: str) -> str`
Invokes the **Business Analyst (BA)** agent to write user stories and requirements.
- **Capabilities:** `ba`, `requirements`
- **Output:** List of `UserStory` models with Gherkin acceptance criteria
- **Context domains queried:** `architecture`, `project`

#### `run_cto(request: str) -> str`
Invokes the **CTO agent** for architectural guidance and advisories.
- **Capabilities:** `cto`, `architecture`, `advisory`
- **Output:** `AgentAdvice` model with bottlenecks, recommendations, and approval
- **Context domains queried:** `adrs`, `architecture`

#### `run_backend(request: str) -> str`
Invokes the **Backend Engineer agent** to generate high-concurrency Go services.
- **Capabilities:** `backend`, `implementation`
- **Output:** `Artifact` model with Go source files (Hexagonal Architecture)
- **Context domains queried:** `adrs`, `architecture`, `dependencies`, `conventions`

#### `run_frontend(request: str) -> str`
Invokes the **Frontend Engineer agent** to generate user interfaces.
- **Capabilities:** `frontend`, `implementation`
- **Output:** `Artifact` model with Vue 3 / TSX source files
- **Context domains queried:** `adrs`, `architecture`, `dependencies`

#### `run_database(request: str) -> str`
Invokes the **Database agent** to generate schema migrations and seed scripts.
- **Capabilities:** `database`, `db_schema`, `migrations`
- **Output:** `Artifact` model with PostgreSQL migration files
- **Context domains queried:** `adrs`, `architecture`

#### `run_devops(request: str) -> str`
Invokes the **DevOps agent** to generate CI/CD pipelines and Docker Compose configurations.
- **Capabilities:** `devops`, `ci_cd`, `deployment`
- **Output:** `Artifact` model with CI/CD config files
- **Context domains queried:** `adrs`, `dependencies`

#### `run_docs(request: str) -> str`
Invokes the **Documentation agent** to generate API documentation and READMEs.
- **Capabilities:** `docs`, `documentation`
- **Output:** `Artifact` model with documentation files
- **Context domains queried:** `conventions`

#### `run_sre(request: str) -> str`
Invokes the **SRE agent** to generate Kubernetes/Helm infrastructure manifests.
- **Capabilities:** `sre`, `infrastructure`
- **Output:** `Artifact` model with K8s manifests
- **Context domains queried:** `adrs`, `architecture`, `dependencies`

#### `run_test_eng(request: str) -> str`
Invokes the **Test Engineer agent** to run tests and analyze coverage.
- **Capabilities:** `test`, `testing`
- **Output:** `Artifact` model with test files
- **Context domains queried:** `conventions`, `architecture`

#### `run_test_gen(request: str) -> str`
Invokes the **Test Generator agent** to write unit and table-driven tests.
- **Capabilities:** `test_gen`, `test_generation`
- **Context domains queried:** `conventions`

#### `run_go_test(request: str) -> str`
Invokes the **Go Testing agent** to run tests and debug test failures.
- **Capabilities:** `go_test`, `go_testing`
- **Context domains queried:** `conventions`

#### `run_review(request: str) -> str`
Invokes the **Code Review agent** to verify production readiness and standards.
- **Capabilities:** `review`, `code_review`
- **Output:** `ReviewResult` model with approval status, feedback, security score, and risk level
- **Context domains queried:** `adrs`, `architecture`, `conventions`

#### `run_security(request: str) -> str`
Invokes the **Security agent** to audit code and scan for vulnerabilities.
- **Capabilities:** `security`, `audit`
- **Output:** `SecurityReport` model with pass/fail, score, and feedback
- **Context domains queried:** `adrs`, `architecture`

#### `run_ux(request: str) -> str`
Invokes the **UX Design agent** to refine page layout and flow.
- **Capabilities:** `ux`, `design`
- **Output:** `Artifact` model with UX design files
- **Context domains queried:** `architecture`

#### `run_quality_gate(request: str) -> str`
Invokes the **Quality Gate agent** to check for over-engineering and complexity.
- **Capabilities:** `quality_gate`, `review`
- **Output:** `QualityGateResult` model with passed status, complexity score (0-100), and feedback
- **Context domains queried:** `adrs`, `architecture`, `conventions`

#### `run_service_engineer(request: str) -> str`
Invokes the **Service Engineer agent** to modify existing Go codebases.
- **Capabilities:** `service_engineer`, `existing_code`, `implementation`
- **Output:** `Artifact` model with only the changed files
- **Context domains queried:** `adrs`, `architecture`, `dependencies`, `project`
- **Tools available:** `read_file`, `list_directory`, `run_gofmt_check`

#### `run_planner(request: str) -> str`
Invokes the **Planner agent** to create execution plans.
- **Capabilities:** `plan`, `planning`
- **Output:** Execution plan with ordered tasks, dependencies, and assigned capabilities
- **Context domains queried:** `adrs`, `architecture`, `project`

#### `run_accountant(request: str) -> str`
Invokes the **Accountant Agent** for budget management and expense calculation.
- **Capabilities:** `finance`
- **Dependencies:** `AccountantDeps`

#### `run_asymmetric_reviewer(request: str) -> str`
Invokes the **Asymmetric Reviewer Agent** for corporate/legal travel savings and loophole identification.
- **Capabilities:** `legal`, `finance`
- **Dependencies:** `AsymmetricReviewerDeps`

#### `run_current_events(request: str) -> str`
Invokes the **Current Events Agent** for modern news blended with historical context.
- **Capabilities:** `news`, `history`
- **Dependencies:** `CurrentEventsDeps`

#### `run_region_analyzer(request: str) -> str`
Invokes the **Region Analyzer Agent** for cost-of-living, safety, and geographical analysis.
- **Capabilities:** `analysis`
- **Dependencies:** `RegionAnalyzerDeps`

#### `run_weather(request: str) -> str`
Invokes the **Weather Agent** for forecasts and climate summaries.
- **Capabilities:** `weather`
- **Dependencies:** `WeatherDeps`

#### `run_crypto_oracle(request: str) -> str`
Invokes the **Crypto Oracle Agent** to analyze crypto markets and trends.
- **Capabilities:** `finance`, `news`, `research`
- **Dependencies:** `CryptoOracleDeps`

#### `run_holiday_planner(request: str) -> str`
Invokes the **Holiday Planner Agent** for itinerary organization and travel coordination.
- **Capabilities:** `planning`, `travel`
- **Dependencies:** `HolidayPlannerDeps`

#### `run_market_shark(request: str) -> str`
Invokes the **Market Shark Agent** to analyze stock markets and investments.
- **Capabilities:** `finance`, `crypto`, `stocks`, `investing`
- **Dependencies:** `MarketSharkDeps`

#### `run_price_analyst(request: str) -> str`
Invokes the **Price Analyst Agent** to analyze and compare pricing.
- **Capabilities:** `pricing`, `analysis`, `purchasing`
- **Dependencies:** `PriceAnalystDeps`

---

### Orchestration Tools

#### `delegate_to_orchestration_agent(capability: str, context: str, task: str) -> str`
Delegate a heavy-lifting engineering task to an Orgitration autonomous agent.

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `capability` | `str` | Agent capability string (e.g., `backend`, `frontend`, `security`, `review`) |
| `context` | `str` | Context from the IDE/caller |
| `task` | `str` | The specific task for the target agent |

**Returns:** Agent's response string.

**Process:**
1. `register_all_agents()` is called to ensure the registry is populated
2. A unified prompt is assembled from `context` and `task`
3. `instrumented_query()` runs the agent with Logfire telemetry

#### `list_orchestration_capabilities() -> str`
List all currently registered agent capabilities with their primary owning agent.

**Returns:** Formatted string listing all capabilities.

#### `run_orchestration_pipeline(project_name: str, requirement: str) -> str`
Run the entire multi-agent Orgitration pipeline end-to-end.

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `project_name` | `str` | Name of the project to isolate outputs and checkpoints |
| `requirement` | `str` | The requirement description |

**Returns:** Run ID for polling (`pipe_{uuid}`).

**Pipeline Stages:**
1. **BA** — Converts requirements into user stories with Gherkin acceptance criteria
2. **Advisory** — CTO architecture review
3. **Implementation** — Backend, Frontend, Database, Tests, DevOps, Docs, SRE
4. **Quality Gate** — Quality gate + Code review

**Note:** The pipeline runs as a background task. Poll for completion with `check_pipeline_status`.

#### `check_pipeline_status(run_id: str) -> str`
Check the status of a background pipeline run.

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `run_id` | `str` | The run ID returned by `run_orchestration_pipeline` |

**Returns:** Status string (pending/running/completed/failed) with optional result and error.

#### `plan_and_execute(goal: str) -> str`
Creates a plan to achieve a high-level goal and executes all tasks in dependency order.

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `goal` | `str` | The high-level goal to achieve |

**Process:**
1. Planner agent creates a plan with ordered tasks and dependencies
2. Tasks are executed in batches based on dependency resolution
3. Each task is delegated to the appropriate agent by capability
4. Results are collected and a summary is returned

**Maximum delegation depth:** 3 levels to prevent infinite loops.

#### `modify_existing_code(change_description: str, codebase_path: str = "") -> str`
Modify existing Go backend code through a multi-agent pipeline.

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `change_description` | `str` | What to change and why |
| `codebase_path` | `str` | Path to the existing codebase root (leave empty for auto-detect) |

**Pipeline Flow (Autonomous Remediation Loop):**
```
service_engineer → [parallel: quality_gate + code_reviewer] → auto-remediation (up to 3 retries)
```

**Retry Logic:**
- Max 3 retries with automated remediation
- Each retry includes specific error context from the failed gates
- After max retries, escalated with a full failure report

**Returns:** Formatted summary including changed files, test files, quality gate score, review status, and any errors.

#### `scaffold_and_build_service(service_name: str, bounded_context: str, requirement: str = "") -> str`
Scaffold and build a new backend service from scratch using the full Orgitration pipeline.

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `service_name` | `str` | Name of the service |
| `bounded_context` | `str` | DDD bounded context name |
| `requirement` | `str` | Optional requirements text |

**Pipeline:** BA → Advisory → Implementation → Test → SRE → Review

---

### Knowledge Management Tools

#### `search_adrs(query: str) -> str`
Search existing Architecture Decision Records (ADRs) in the vector knowledge base.

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `query` | `str` | Search query |

**Returns:** Formatted ADR snippets or "No ADRs found" message.

#### `save_adr(decision_id: str, content: str) -> str`
Save a new Architecture Decision Record (ADR) to the knowledge base.

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `decision_id` | `str` | Unique identifier for the ADR |
| `content` | `str` | Full ADR content |

**Returns:** Confirmation message.

#### `seed_project_context(project_path: str) -> str`
Seed the vector DB with project files (rules, workflows, READMEs, ADRs).

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `project_path` | `str` | Absolute path to the project root |

**Scanned Patterns:**
- `.agents/rules/*.md`, `.agents/workflows/*.md`
- `ARCHITECTURE*.md`, `CONVENTIONS*.md`, `CODING_STANDARDS*.md`, `CONTRIBUTING*.md`
- `*.adr`
- `*.md` in root

**Domain classification:** `conventions`, `adrs`, `project`, `architecture`

#### `query_context(query: str, domain: str = "", top_k: int = 5) -> str`
Query the vector DB directly for relevant context about any topic.

**Parameters:**
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `query` | `str` | — | What to search for |
| `domain` | `str` | `""` | Optional domain filter (`adrs`, `architecture`, `conventions`, `project`) |
| `top_k` | `int` | `5` | Max results per domain |

**Returns:** Formatted context snippets grouped by domain.

#### `task_context(task_id: str) -> str`
Get full context from the vector DB about a specific completed async task.

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `task_id` | `str` | The task ID to look up |

---

### Async Task Tools

#### `submit_async_task(task_type: str, payload: str, callback_tool: str = "") -> str`
Submit a heavy task for asynchronous execution via the internal event broker.

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `task_type` | `str` | One of `build`, `test_suite`, `deploy`, `pipeline` |
| `payload` | `str` | JSON payload with task parameters |
| `callback_tool` | `str` | Optional tool name to call on completion |

**Returns:** Task ID for polling.

#### `check_task_status(task_id: str) -> str`
Check the status of an async task submitted via `submit_async_task`.

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `task_id` | `str` | The task ID to check |

**Returns:** Task status and result.

#### `wait_for_task(task_id: str, timeout_seconds: int = 300) -> str`
Wait synchronously for an async task to complete.

**Parameters:**
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `task_id` | `str` | — | The task ID to wait for |
| `timeout_seconds` | `int` | `300` | Maximum wait time |

---

### Memory Bridge Tools

#### `sync_memory(all_runtimes: bool = True, max_entries: int = 50) -> str`
Sync memory across all agent runtimes (pgvector ↔ Claude Code ↔ Antigravity).

**Parameters:**
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `all_runtimes` | `bool` | `True` | If `True`, sync to both Claude Code and Antigravity |
| `max_entries` | `int` | `50` | Max recent pgvector entries to process |

**Returns:** Sync summary with entry counts.

#### `memory_bridge_status() -> str`
Get the current status of all memory systems.

**Returns:** Status including Claude Code agent memory counts, Antigravity entries, and pgvector table health.

---

## CLI Pipeline API

The CLI pipeline is the command-line entry point for running the full SDLC pipeline.

### Usage

```bash
python main.py [OPTIONS]
```

### Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `--step` | `str` | `all` | Pipeline step or agent name. Choices: `ba`, `advisory`, `implementation`, `backend`, `frontend`, `database`, `test`, `devops`, `docs`, `quality_gate`, `sre`, `review`, `security`, `all` |
| `--project` | `str` | `default` | Project name to isolate outputs and checkpoints |
| `--requirement` | `str` | `None` | Custom requirement text |
| `--resume` | flag | `False` | Resume from last checkpoint |
| `--yes` | flag | `False` | Skip human-in-the-loop confirmation |
| `--dry-run` | flag | `False` | Run pipeline with mock data (no LLM calls) |

### Pipeline Stages

| Stage | Agent(s) | Description |
|-------|----------|-------------|
| `ba` | Business Analyst | Converts requirements into user stories with Gherkin criteria |
| `advisory` | CTO | Architecture review and advisories |
| `implementation` | Backend, Frontend, Database, Test, DevOps, Docs | Full implementation per user story |
| `quality_gate` | Quality Gate, SRE, Review, Security | Verification gates |

### Implementation Retry Loop

When running the full pipeline (`--step all`), the implementation stage includes an autonomous retry loop:

1. Backend implementation per user story
2. Frontend implementation per user story
3. Database schema generation per user story
4. Parallel: DevOps (CI/CD) + Docs
5. Test generation per user story
6. If tests fail → retry implementation with failure context
7. Quality Gate runs
8. Max retries: `settings.max_retries` (default: 3)

---

## Capability-Based Agent Registry

The `AgentRegistry` class provides a capability-based lookup system.

### Registry API

#### `registry.register(name, agent, capabilities, deps_factory=None, post_process_hook=None)`
Register an agent with its capabilities.

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | `str` | Unique agent name |
| `agent` | `Agent` | pydantic_ai Agent instance |
| `capabilities` | `list[str]` | List of capability strings |
| `deps_factory` | `callable` | Optional factory for dependency objects |
| `post_process_hook` | `callable` | Optional post-processing hook |

#### `registry.query(capability, prompt, timeout=None, deps=None) -> str`
Query an agent by capability.

**Raises:**
- `AgentNotFoundError` — if no agent claims the capability
- `AgentExecutionError` — if the agent run fails

#### `registry.owners_of(capability) -> list[str]`
Return the ordered list of agent names that claim a capability.

#### `registry.list_agents() -> list[str]`
List all registered agent names.

#### `registry.capabilities() -> list[tuple[str, list[str]]]`
Return (capability, owners) pairs in sorted order.

### Capability Map

| Capability | Primary Agent | Also Claimed By |
|------------|--------------|-----------------|
| `ba` | ba | — |
| `requirements` | ba | — |
| `cto` | cto | — |
| `architecture` | cto | — |
| `advisory` | cto | — |
| `backend` | backend | — |
| `implementation` | backend, service_engineer | — |
| `frontend` | frontend | — |
| `frontend_component` | frontend_component | — |
| `database` | database | — |
| `db_schema` | database | — |
| `migrations` | database | — |
| `devops` | devops | — |
| `ci_cd` | devops | — |
| `deployment` | devops | — |
| `docs` | docs | — |
| `documentation` | docs | — |
| `sre` | sre | — |
| `infrastructure` | sre | — |
| `test` | test_eng | — |
| `testing` | test_eng | — |
| `test_gen` | test_gen | — |
| `test_generation` | test_gen | — |
| `go_test` | go_test | — |
| `go_testing` | go_test | — |
| `review` | review, quality_gate | — |
| `code_review` | review | — |
| `security` | security | — |
| `audit` | security | — |
| `ux` | ux | — |
| `design` | ux | — |
| `quality_gate` | quality_gate | — |
| `service_engineer` | service_engineer | — |
| `existing_code` | service_engineer | — |
| `plan` | planner | — |
| `planning` | planner, holiday_planner | — |
| `finance` | accountant, asymmetric_reviewer, crypto_oracle, market_shark | — |
| `legal` | asymmetric_reviewer | — |
| `news` | current_events, crypto_oracle | — |
| `history` | current_events | — |
| `analysis` | region_analyzer, price_analyst | — |
| `weather` | weather | — |
| `research` | crypto_oracle | — |
| `travel` | holiday_planner | — |
| `crypto` | market_shark | — |
| `stocks` | market_shark | — |
| `investing` | market_shark | — |
| `pricing` | price_analyst | — |
| `purchasing` | price_analyst | — |

---

## Data Models

### `UserStory`

| Field | Type | Description |
|-------|------|-------------|
| `id` | `str` | Story ID (e.g., `ORDERS-01`) |
| `title` | `str` | Story title |
| `gherkin` | `str` | Given/When/Then acceptance criteria |
| `event_triggers` | `list[EventTrigger]` | Domain events triggered by this story |

### `EventTrigger`

| Field | Type | Description |
|-------|------|-------------|
| `id` | `str` | Event identifier |
| `name` | `str` | Event name |
| `description` | `str` | Event description |

### `Artifact`

| Field | Type | Description |
|-------|------|-------------|
| `agent_name` | `str` | Name of the agent that produced the artifact |
| `files` | `dict[str, str]` | Map of file paths to their contents |
| `metadata` | `dict[str, Any]` | Metadata (user_story_id, service_name, language, framework) |

### `ReviewResult`

| Field | Type | Description |
|-------|------|-------------|
| `approved` | `bool` | Whether the code is approved |
| `feedback` | `list[str]` | Review feedback items |
| `security_score` | `int` | Security score (0-100) |
| `risk_level` | `RiskLevel` | Risk level (LOW, MEDIUM, HIGH, CRITICAL) |

### `QualityGateResult`

| Field | Type | Description |
|-------|------|-------------|
| `passed` | `bool` | Whether quality gate passed |
| `complexity_score` | `int` | Complexity score (0-100, 0=simple, 100=over-engineered) |
| `feedback` | `list[str]` | Quality gate feedback |

### `AgentAdvice`

| Field | Type | Description |
|-------|------|-------------|
| `bottlenecks_identified` | `list[str]` | Potential issues or bottlenecks |
| `recommendations` | `list[str]` | Actionable advice for downstream agents |
| `approved_to_proceed` | `bool` | Whether to proceed with implementation |

### `FailureReport`

| Field | Type | Description |
|-------|------|-------------|
| `source` | `str` | Stage or agent that produced the failure |
| `error_type` | `str` | Category of failure (compilation, security, test, etc.) |
| `trace` | `str` | Detailed error trace or feedback |
| `relevant_files` | `list[str]` | Files related to the failure |

### `PipelineState`

| Field | Type | Description |
|-------|------|-------------|
| `run_id` | `str` | Unique pipeline run identifier |
| `stage` | `str` | Current pipeline stage |
| `attempt` | `int` | Current retry attempt number |
| `user_stories` | `list[UserStory]` | Generated user stories |
| `advisory_results` | `dict[str, str]` | Results from advisory stage |
| `cto_approved` | `bool` | CTO gate approval |
| `approved` | `bool` | Overall pipeline approval |
| `artifacts` | `list[Artifact]` | Generated artifacts |
| `feedback` | `str` | Optional feedback |
| `failure_report` | `FailureReport` | Optional failure report |

### `ExistingCodeResult`

| Field | Type | Description |
|-------|------|-------------|
| `passed` | `bool` | Whether the pipeline passed |
| `changed_files` | `list[str]` | Files that were changed |
| `artifacts` | `list[Artifact]` | Generated artifacts |
| `test_files` | `list[str]` | Test files that were generated |
| `quality_gate_score` | `int` | Quality gate complexity score |
| `quality_gate_feedback` | `list[str]` | Quality gate feedback |
| `review_approved` | `bool` | Whether review approved |
| `review_risk` | `str` | Review risk level |
| `errors` | `list[str]` | Errors encountered |
| `retries_used` | `int` | Number of retries used |

### `Event`

| Field | Type | Description |
|-------|------|-------------|
| `kind` | `EventKind` | Event type enum |
| `data` | `dict[str, Any]` | Event payload |
| `id` | `str` | Unique event ID |
| `timestamp` | `float` | Unix timestamp |

### `EventKind` Enum

| Value | Description |
|-------|-------------|
| `TASK_SUBMITTED` | A new task was submitted |
| `TASK_STARTED` | A task started processing |
| `TASK_COMPLETED` | A task completed successfully |
| `TASK_FAILED` | A task failed |
| `TASK_TIMEOUT` | A task timed out |

### `RiskLevel` Enum

| Value | Description |
|-------|-------------|
| `LOW` | Low risk |
| `MEDIUM` | Medium risk |
| `HIGH` | High risk |
| `CRITICAL` | Critical risk |

### `ActivityLog`

| Field | Type | Description |
|-------|------|-------------|
| `pass_num` | `int` | Pass number in the pipeline |
| `agent_name` | `str` | Name of the agent |
| `action` | `str` | Action performed |
| `summary` | `str` | Summary of the action |
| `timestamp` | `str` | ISO 8601 timestamp |
| `artifact_ids` | `list[str]` | IDs of related artifacts |

### `SecurityReport`

| Field | Type | Description |
|-------|------|-------------|
| `passed` | `bool` | Whether security checks passed |
| `score` | `int` | Security score |
| `feedback` | `list[str]` | Security feedback |

---

## Configuration Reference

All configuration is managed through `Settings` (pydantic-settings, loaded from `.env`).

### Environment Variables

#### LLM Providers

| Variable | Type | Description |
|----------|------|-------------|
| `OPENAI_API_KEY` | `str` | OpenAI API key |
| `ANTHROPIC_API_KEY` | `str` | Anthropic API key |
| `GEMINI_API_KEY` | `str` | Google Gemini API key |
| `DEEPSEEK_API_KEY` | `str` | DeepSeek API key |

#### Observability

| Variable | Type | Description |
|----------|------|-------------|
| `LOGFIRE_TOKEN` | `str` | Logfire telemetry token |
| `LOGFIRE_SEND_TO_LOGFIRE` | `bool` | Enable Logfire sending |

#### Database

| Variable | Type | Description |
|----------|------|-------------|
| `DATABASE_URL` | `str` | PostgreSQL connection string for pgvector |

#### Model Configuration

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `model_provider` | `str` | `deepseek` | Provider override (deepseek, openai, gemini, vertexai) |
| `ba_model` | `str` | `deepseek-reasoner` | BA agent model |
| `backend_model` | `str` | `deepseek-reasoner` | Backend agent model |
| `frontend_model` | `str` | `deepseek-chat` | Frontend agent model |
| `test_model` | `str` | `deepseek-reasoner` | Test agent model |
| `sre_model` | `str` | `deepseek-reasoner` | SRE agent model |
| `review_model` | `str` | `deepseek-reasoner` | Review agent model |
| `database_model` | `str` | `deepseek-reasoner` | Database agent model |
| `devops_model` | `str` | `deepseek-reasoner` | DevOps agent model |
| `docs_model` | `str` | `deepseek-chat` | Docs agent model |
| `security_model` | `str` | `deepseek-reasoner` | Security agent model |
| `ux_model` | `str` | `deepseek-chat` | UX agent model |
| `cto_model` | `str` | `deepseek-reasoner` | CTO agent model |

#### Pipeline Configuration

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `output_dir` | `Path` | `./generated-app` | Output directory for artifacts |
| `max_retries` | `int` | `3` | Max retries before escalation |
| `max_concurrent_llm_calls` | `int` | `5` | Max concurrent LLM calls |
| `checkpoint_dir` | `Path` | `./.claw-checkpoints` | Checkpoint storage directory |
| `vector_db_dir` | `Path` | `./.claw-vectordb` | Vector DB storage directory |
| `go_version` | `str` | `1.26` | Go version for backend generation |

#### Redis (Iris)

| Variable | Type | Description |
|----------|------|-------------|
| `REDIS_IRIS_URL` | `str` | Redis Iris connection URL |
| `REDIS_IRIS_STORE_ID` | `str` | Redis Iris store ID |
| `REDIS_IRIS_TOKEN` | `str` | Redis Iris authentication token |

### Model Resolution

The `resolve_model()` method maps agent model names to fully-qualified pydantic_ai model specs based on the provider:

| Provider | Resolution |
|----------|-----------|
| `deepseek` | `deepseek:{model_name}` |
| `openai` | `openai:gpt-4o` (all agents) |
| `gemini` | `gemini:gemini-2.0-flash` (all agents) |
| `vertexai` | `vertexai:gemini-2.0-flash` (all agents) |

**Model tiers:**
- **Fast tier** (cheaper/faster): frontend, docs, ux, ba, holiday_planner, region_analyzer, current_events, weather
- **Reasoner tier** (more capable): backend, test, review, security, quality_gate, sre, database, devops, cto, asymmetric_reviewer, accountant, price_analyst, market_shark, crypto_oracle

---

## Error Handling

### Exception Hierarchy

```
OrgitrationError (base)
├── ConfigurationError        — Invalid/missing configuration
├── AgentNotFoundError        — Agent not registered
├── AgentExecutionError       — LLM call or tool execution failed
│   └── .is_retryable: bool   — Whether the error can be retried
├── PipelineError             — Pipeline-level failure
│   └── PipelineStepFailedError — Specific step failed
├── ValidationError           — Code or data validation failed
├── CheckpointError           — Checkpoint save/load/clear failed
└── PathTraversalError        — Path traversal detected (security)
```

### MCP Error Responses

When agents fail during MCP execution, errors are wrapped with `AgentExecutionError` or `AgentNotFoundError` and returned as descriptive strings prefixed with `ERROR:`.

### Pipeline Failure Recovery

- **Test failures:** Implementation is retried with failure context (up to `max_retries`)
- **Quality gate failures:** Parallel gates (quality_gate + review) validate output; failures trigger auto-remediation
- **Existing code pipeline:** Up to 3 retries, then escalation to Lead Orchestrator

---

## Tool Categories

Each agent is assigned tool categories that control which tools are wired into the agent at initialization.

| Agent | Tool Categories |
|-------|-----------------|
| `ba` | web, memory, documentation, a2a |
| `backend` | web, search, security, validation, deps, memory, a2a |
| `frontend` | web, search, deps, memory, a2a |
| `frontend_component` | web, search, deps, memory, documentation, a2a |
| `test_eng`, `test_gen`, `go_test` | search, validation, memory, a2a |
| `sre` | web, security, validation, deps, memory, a2a |
| `quality_gate` | validation, memory, a2a |
| `review` | security, memory, documentation, a2a |
| `security` | search, security, memory, a2a |
| `docs` | web, documentation, a2a |
| `cto` | search, memory, documentation, a2a |
| `ux` | web, search, memory, documentation, a2a |
| `planner` | web, search, memory, a2a, planning |
| `service_engineer` | search, memory, a2a |
| `price_analyst` | web, search, memory, a2a, pricing |
| `holiday_planner` | web, search, memory, a2a, planning |
| `market_shark` | web, search, memory, a2a, finance |
| `crypto_oracle` | web, search, memory, finance, news, a2a |
| `database`, `devops` | web, search, memory, documentation, a2a |
| `accountant` | web, search, memory, a2a |
| `asymmetric_reviewer` | web, search, memory, a2a |
| `current_events` | web, search, memory, a2a |
| `region_analyzer` | web, search, memory, a2a |
| `weather` | web, search, memory, a2a |

### Available Tools by Category

| Category | Tools |
|----------|-------|
| `a2a` | `discover_agent_capabilities`, `delegate_to_agent` |
| `web` | Web fetching and scraping tools |
| `search` | `search_codebase`, `search_pattern_in_content`, `search_files` |
| `security` | Security scanning and vulnerability detection |
| `validation` | Code validation and standards checking |
| `deps` | Dependency management tools |
| `memory` | Vector DB memory tools |
| `documentation` | Documentation generation tools |
| `finance` | `get_stock_ticker_data`, `get_historical_prices` |
| `pricing` | Comparative pricing analysis |
| `planning` | Task planning and scheduling |
