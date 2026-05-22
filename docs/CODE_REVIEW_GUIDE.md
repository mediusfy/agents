# OpenClaw Code Review Guide

A living document for reviewing the OpenClaw multi-agent SDLC ecosystem. Covers project structure, design patterns, inter-agent communication, testing posture, and prioritized next steps.

---

## 1. Project Structure & Features

```
src/openclaw/
├── agents/                  # Agent definitions (one per role)
│   ├── non_technical/       # Holiday planner, weather, market, crypto, price
│   ├── ba.py                # Business Analyst — user stories → bounded contexts
│   ├── backend.py           # Go backend service engineer
│   ├── frontend.py          # Vue 3 TSX component engineer
│   ├── test_eng.py          # Playwright & Go table-driven test generation
│   ├── database.py          # PostgreSQL migrations, Redis, schema design
│   ├── devops.py            # CI/CD, Docker Compose, Makefiles
│   ├── docs.py              # OpenAPI specs, READMEs
│   ├── sre.py               # Terraform, K8s, multi-cloud
│   ├── security.py          # OWASP audits
│   ├── ux.py                # UX review
│   ├── cto.py               # Architectural pressure-test
│   ├── review.py            # Final governance review
│   ├── quality_gate.py      # Over-engineering detector
│   ├── planner_agent.py     # Task planner
│   ├── service_engineer.py  # Modify existing Go code
│   ├── region_analyzer.py   # Regional analysis
│   ├── accountant.py        # Budget/finance
│   ├── asymmetric_reviewer.py  # Legal/corporate travel savings
│   ├── current_events.py    # Historical context
│   ├── weather.py           # Weather data
│   └── registration.py      # Agent auto-discovery
├── models/
│   └── core.py              # Shared Pydantic models
├── tools/
│   ├── a2a_tools.py         # Agent-to-agent delegation
│   ├── search.py            # Web search
│   ├── web_fetch.py         # URL fetching
│   ├── market_tools.py      # Financial data
│   ├── travel_finance.py    # Travel cost analysis
│   ├── memory.py            # Agent memory access
│   ├── secrets.py           # Secret management
│   ├── deps.py              # Dependency management
│   ├── docs.py              # Documentation search
│   └── validate.py          # Validation utilities
├── registry.py              # AgentRegistry — capability-based O(1) dispatch
├── settings.py              # Pydantic-settings configuration
├── healthcheck.py           # Startup validation
├── checkpoint.py            # Pipeline checkpoint/restore
├── telemetry.py             # Logfire instrumentation wrapper
├── planning.py              # Plan model & executor
├── gates.py                 # Quality gates
├── validators.py            # Output validation
├── vector_db.py             # ChromaDB memory backend
├── memory.py                # Memory consolidation
├── writer.py                # Artifact writer
├── mcp_server.py            # MCP SSE server
├── exceptions.py            # Custom exceptions
└── utils.py                 # Shared utilities
```

**Features:**
- Multi-agent SDLC pipeline: BA → CTO → Backend → Frontend → Database → DevOps → Docs → SRE → Test → Review
- Agent-to-agent (A2A) delegation via capability registry
- Checkpoint/resume for long-running pipelines
- Telemetry via Logfire
- Vector DB memory for cross-agent context
- MCP server for IDE integration
- Quality gates & over-engineering detection

---

## 2. Design Patterns

### 2.1 Agent Registry (Registry Pattern)
`openclaw/registry.py` — Central `AgentRegistry` with O(1) capability lookup. Agents register with `name, agent, capabilities[], deps_factory, post_process_hook`. Querying by capability avoids linear scans.

**Status:** Well-designed, but the `items()` method returns 4-tuples that some consumers unpack as 3-tuples (fixed in `a2a_tools.py`). Needs type annotations.

### 2.2 Pydantic-Settings Configuration
`settings.py` — Environment-driven configuration with `.env` file support. Per-agent model overrides enable fine-grained model selection.

**Recommendation:** Add a `resolve_model()` helper that maps model name strings to provider-specific model objects (already done for DeepSeek). Currently all agents use `deepseek-chat` — consider adding a tiered model strategy where complex reviews use `deepseek-reasoner` (but note: DeepSeek reasoning models don't support tool calls).

### 2.3 Tool Injection
`tools/registry.py` + `tool_assignments.py` — Tools are registered globally and injected into agents based on capability categories. Decouples tool definitions from agent logic.

**Status:** Clean separation. However, the tool registration is overly broad — some agents receive tools they never use.

### 2.4 Checkpoint/Restore
`checkpoint.py` — Pipeline state is serialized to disk, allowing resume on failure. Essential for long multi-stage pipelines.

**Status:** Works but untested in CI. The checkpoint format is tightly coupled to `PipelineState` schema — schema changes break resume compatibility.

### 2.5 Telemetry Wrapper
`telemetry.py` — Thin wrapper around Logfire for auto-instrumentation of agent runs.

**Status:** Simple and effective. Should add span attributes for model name, token usage, and latency.

---

## 3. Inter-Agent Communication

### 3.1 How It Works
Communication follows a **pipeline orchestration** model, not a mesh:
1. `main.py` orchestrates stages sequentially (BA → CTO → Backend → ...)
2. Within a stage, the orchestrator invokes an agent with a prompt
3. Agents can do A2A delegation via `delegate_to_agent()` tool, which uses the registry's O(1) capability lookup
4. Agent outputs are structured Pydantic models (`UserStory`, `Artifact`, `AgentAdvice`, `ReviewResult`, etc.)

### 3.2 Assessment
| Aspect | Verdict |
|--------|---------|
| Correctness | The registry pattern is sound. A2A delegation works via tool calls |
| Information usefulness | Agent outputs carry rich structured data. However, context passed between stages is diluted — critical decisions from earlier stages may be lost |
| Testing | **Not tested.** There are no integration tests for cross-agent communication. `test_pipeline_integration.py` exists but is skeletal |
| Error handling | Failures in one agent are logged but don't propagate well. The CTO agent failure is silently caught and reported as a string |

### 3.3 Gaps
- No message schema versioning — if an agent's output type changes, downstream consumers break silently
- No timeout propagation — agent A delegating to agent B can't set B's timeout
- No circuit breaker for agent failures in A2A chains
- The planner agent produces a `Plan` but there's no feedback loop to verify plan accuracy after execution

---

## 4. Testing Posture

### 4.1 Current Coverage
```
tests/
├── unit/
│   ├── test_settings.py              ✓ Good
│   ├── test_healthcheck.py           ✓ Adequate
│   ├── test_registry.py              ✓ Basic coverage
│   ├── test_memory.py                ✓ Minimal
│   ├── test_gates.py                 ✓ Present
│   ├── test_telemetry.py             ✓ Present
│   ├── test_writer.py                ✓ Present
│   ├── test_checkpoint_extended.py   ✓ Present
│   ├── test_existing_code_handler.py ✓ Present
│   ├── test_utils.py                 ✓ Present
│   └── test_validators_extended.py   ✓ Present
└── integration/
    └── test_pipeline_integration.py  ✗ Skeletal
```

### 4.2 Gaps
- **Zero integration tests** for the actual pipeline execution
- **No agent-level tests** — every agent file is untested
- **No tool tests** — `a2a_tools.py`, `search.py`, `web_fetch.py`, etc. are untested
- **No mock LLM tests** — tests that verify agents parse model output correctly
- **No regression tests** — the `.data` → `.output` breakage would have been caught
- **Healthcheck tests** mock settings rather than testing real validation logic

### 4.3 DRY Violations & Library Opportunities

| Issue | Where | Recommendation |
|-------|-------|---------------|
| Custom tool registry | `tools/registry.py` | pydantic-ai's native tool system already handles registration — the custom `register_tool()` is redundant |
| Custom MCP server | `mcp_server.py` | Consider FastMCP or an established MCP framework instead of hand-rolling the SSE handler |
| A2A delegation is manual | `a2a_tools.py` | pydantic-ai agents can call each other natively — the custom delegation layer adds complexity without clear benefit |
| Vector DB abstraction | `vector_db.py` | ChromaDB is used directly with LangChain wrappers partially — pick one abstraction and remove the other |
| No rate limiting / retry library | `telemetry.py`, `settings.py` | tenacity is already in deps but not used for LLM calls — add retry with exponential backoff |

---

## 5. Maintainability Assessment

| Metric | Score | Notes |
|--------|-------|-------|
| Module cohesion | 7/10 | Most modules have clear responsibilities. `utils.py` is a junk drawer |
| Coupling | 6/10 | Agents import `settings` directly instead of receiving config via dependency injection |
| Testability | 4/10 | Direct `Agent()` construction at module level makes agents hard to mock. No DI container |
| Documentation | 5/10 | README exists, some inline docstrings. No ADRs for architectural decisions |
| Error handling | 4/10 | Inconsistent — some errors are logged, some caught silently, some crash the pipeline |
| Type coverage | 6/10 | Pydantic models are typed. Many functions lack return type annotations |
| DRY compliance | 5/10 | Repeated Agent construction pattern across 21+ files. Shared prompt boilerplate |

### What Can Be Improved

1. **Dependency Injection** — Pass settings and agent registry via constructor or context instead of module-level imports. Makes testing trivial.

2. **Agent Factory** — A single `AgentFactory` that creates agents with the right model, tools, and dependencies. Eliminates the repeated `Agent(resolve_model(settings.xxx_model), ...)` pattern.

3. **Prompt Management** — Extract prompts into a dedicated directory (`prompts/`) with versioning. Currently prompts are inline strings in agent files.

4. **Circuit Breakers** — When A2A delegation fails, the caller should have retry/fallback logic, not just pass a string error message downstream.

5. **Unified Error Model** — All agents should return `Result[T, ErrorDetail]` instead of mixing exceptions, string errors, and successful return values.

6. **Lock Dependencies** — `uv.lock` exists but major version ranges in `pyproject.toml` (e.g., `>=1.0.0,<2.0` for pydantic-ai) allowed the `.data` → `.output` breakage to slip in.

---

## 6. Next Steps

### Immediate (High Impact, Low Effort)
- [ ] **Add mock LLM tests** for each agent — test that prompts produce expected output structures without calling real APIs. Use `pytest` + `Agent` with a mock model.
- [ ] **Lock pydantic-ai version range** to patch-only (`~=1.61.0`) to prevent future API breakage.
- [ ] **Remove `utils.py`** — distribute its functions into relevant modules.
- [ ] **Add CI step** that runs `make run-dry-run` to verify the pipeline initializes without errors.

### Short-term (Medium Impact)
- [ ] **Create `AgentFactory`** — centralize Agent construction, model resolution, and tool injection into one factory class.
- [ ] **Write integration tests** for the BA → CTO → Backend handoff. Verify structured output flows between stages.
- [ ] **Add telemetry spans** for each stage with model name, token count, and latency.

### Medium-term (High Impact)
- [ ] **Pydantic-based error types** — replace string error returns with typed `AgentError` variants.
- [ ] **Prompt catalog** — extract prompts to `prompts/*.j2` Jinja2 templates with schema-validated variables.
- [ ] **Cross-agent feedback loop** — after the pipeline completes, run a reconciliation step that validates the final output against the original BA user stories.

### Long-term (Architectural)
- [ ] **Event-driven agent mesh** — instead of sequential orchestration, route agent work through a NATS/Redis event bus. Each agent subscribes to event types it handles.
- [ ] **Scoped tool permissions** — agents should only receive tools relevant to their role, enforced at registration time, not at query time.
- [ ] **Observability dashboard** — Logfire traces + custom metrics for agent latency, success rates, token consumption per stage.

---

## 7. Review Checklist

When reviewing a PR in this repo:

- [ ] Does the code use an existing library instead of reinventing? Check `pyproject.toml` before writing new utilities.
- [ ] Is the `Agent()` construction through the factory (or at minimum using `resolve_model()`)?
- [ ] Are there tests? New agents must have a mock-model test that verifies output parsing.
- [ ] Is there a new capability that needs to be registered in the `AgentRegistry`?
- [ ] Does the change break checkpoint compatibility?
- [ ] Are prompts kept in the code (inline is acceptable for now) or have they drifted into a separate file without updating the convention?
- [ ] Is `settings.py` the single source of truth for configuration — no hardcoded model names or API keys in agent files?
- [ ] Does the change increase or decrease the number of untested paths?
