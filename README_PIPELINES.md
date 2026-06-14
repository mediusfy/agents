# Pipeline Frameworks

Orgitration runs the same pool of Pydantic AI agents through three different orchestration engines. Each solves a different coordination problem. You pick the framework that matches your workflow's shape.

---

## Framework Guide

| Framework | Pattern | Best for | Complexity |
|-----------|---------|----------|------------|
| **LangGraph** | Stateful graph with cycles, conditional routing, retry | Deterministic multi-stage pipelines, error recovery, autonomous loops | High |
| **CrewAI** | Role-based sequential delegation | Simple linear workflows, research teams, clearly defined handoffs | Low |
| **AutoGen** | Multi-agent group chat conversations | Design discussions, debugging sessions, exploratory problem-solving | Medium |

### LangGraph

A directed state machine compiled from nodes and edges. Each node is a pipeline stage (BA, advisory, implementation, quality gate). Edges have conditional routers that inspect state and decide the next node.

The implementation stage is itself a sub-graph with an autonomous retry loop: implement -> test -> quality gate -> retry if failed -> up to N attempts.

**Use when:** You need deterministic orchestration with loops, branching, and the ability to resume from checkpoints.

```
START -> BA -> advisory -> [ implement -> test -> quality gate ] -> merge -> END
                                 ^               |
                                 +--- retry ------+
```

### CrewAI

A crew of agents assigned to tasks in sequence. Each agent has a role, goal, and backstory extracted from the Pydantic AI agent definition. Tasks feed outputs to downstream tasks as context.

**Use when:** You want a simple sequential pipeline with minimal configuration, or parallel research crews.

```python
crew = Crew(
    agents=[ba, cto, backend, frontend, qa, reviewer],
    tasks=[refine, review_arch, implement, frontend, test, review],
    process=Process.sequential,
)
```

### AutoGen

A round-robin or auto-selected group chat where agents converse to refine a problem. The conversation terminates after a configurable number of rounds or when the manager decides the goal is met.

**Use when:** You need interactive discussion between agents — design debates, bug triage, exploratory analysis.

```
PM: "Build a payment service"
  -> BA: "I've refined these stories..."
  -> CTO: "Architecture should use event sourcing..."
  -> Backend: "Implementing..."
  -> Reviewer: "Approved with notes"
```

---

## Blueprints

Blueprints map framework + stage combinations to a single CLI command. See `pipeline/config.py:BLUEPRINTS`.

| Blueprint | Framework | Stages |
|-----------|-----------|--------|
| `new_feature` | legacy | BA -> Advisory -> Implementation -> Quality Gate |
| `quick_backend` | legacy | Implementation -> Quality Gate |
| `langgraph_full` | LangGraph | BA -> Advisory -> Implementation (retry loop) -> Quality Gate -> Merge |
| `langgraph_quick` | LangGraph | Implementation (retry loop) -> Quality Gate |
| `crew_sdlc` | CrewAI | BA -> CTO -> Backend -> Frontend -> QA -> Review |
| `crew_research` | CrewAI | Weather + Crypto + Market in parallel |
| `autogen_sdlc` | AutoGen | BA + CTO + Backend + Frontend + QA + Reviewer conversation |
| `autogen_design_review` | AutoGen | BA + CTO + Security + UX design discussion |
| `composite` | LangGraph + CrewAI | LangGraph orchestrates; CrewAI handles implementation |

### CLI usage

```bash
# Default (legacy sequential)
python main.py --blueprint new_feature --project myapp

# LangGraph
python main.py --blueprint langgraph_full --project myapp -r "Build a payment service"

# CrewAI (requires: uv sync --extra crewai)
python main.py --blueprint crew_sdlc --project myapp -r "Build a payment service"

# AutoGen (requires: uv sync --extra autogen)
python main.py --blueprint autogen_design_review --project myapp -r "Design payment architecture"

# Override framework
python main.py --blueprint new_feature --framework langgraph --project myapp
```

---

## How Agents Function

All 30+ agents are defined as **Pydantic AI Agents** (`pydantic_ai.Agent`) with:

1. **A model** — resolved through `settings.resolve_model()` supporting DeepSeek, OpenAI, Gemini, LiteLLM
2. **A system prompt** — role-specific (BA, backend engineer, security auditor, etc.)
3. **A typed output** — `UserStory`, `Artifact`, `SecurityReport`, `ReviewResult`, etc.
4. **Custom tools** — registered via `register_tool()` and assigned to agents by category in `tool_assignments.py`

Agents are registered in a central `AgentRegistry` by name and capability. All three frameworks look up agents from the same registry.

### Tool system

Tools are plain Python functions wrapped with name + description + category tags. When an agent is first used (`registry.get("name")`), tools matching the agent's assigned categories are attached via `apply_tools()`.

Tools include:

- **Search**: ripgrep-based code search, web fetch, DuckDuckGo (via LangChain)
- **File I/O**: read, write, list, glob — sandboxed to workspace root
- **Code validation**: `go build`, `go vet` in temp directories
- **Memory**: persistent vector storage for cross-session recall
- **Documentation**: read and update markdown docs
- **Package checking**: PyPI, Go proxy, NPM registry lookups
- **LangChain bridge**: DuckDuckGo search, Wikipedia, arXiv (additive, not required)

### Adapter layer

Each framework has a corresponding adapter in `adapters/` that wraps a Pydantic AI Agent into the framework's native type:

| Adapter | Converts | To |
|---------|----------|----|
| `langgraph_bridge.py` | `StageRunner` / `pydantic_ai.Agent` | LangGraph node (state delta function) |
| `crewai_bridge.py` | `pydantic_ai.Agent` | `crewai.Agent` (extracts role, goal, backstory, tools) |
| `autogen_bridge.py` | `pydantic_ai.Agent` | `autogen.AssistantAgent` (extracts system message, model config, tools) |

---

## Architecture

```
                         CLI / MCP entry point
                                |
                        PipelineConfig
                        (blueprint + framework)
                                |
                     PipelineFactory.build_pipeline()
                        /        |        \
                   LangGraph   CrewAI    AutoGen
                   (graphs/)  (crews/)  (groups/)
                        \        |        /
                     Shared Agent Pool
                     (registry.py + all agents/*.py)
                                |
                     LangChain Tools
                     (tools/langchain_bridge.py)
```

Each framework module lives in its own directory under `pipeline/`:

```
pipeline/
    config.py              # shared: PipelineConfig, Framework enum, BLUEPRINTS
    factory.py             # dispatcher: build_pipeline() routes by framework
    protocols.py           # PipelineOrchestrator protocol
    orchestrator.py        # legacy OrgitrationPipeline (unchanged)

    langgraph/
        graphs.py          # StateGraph definitions
        nodes.py           # node functions
        routing.py         # conditional edge routers

    crewai/
        crews.py           # Crew definitions (SdlcCrew, ResearchCrew, etc.)
        bridge.py          # CrewAI -> PipelineState mapping
        orchestrator.py    # CrewAIPipeline runner

    autogen/
        groups.py          # GroupChat definitions
        bridge.py          # AutoGen -> PipelineState mapping
        orchestrator.py    # AutoGenPipeline runner
```

---

## Production Readiness Checklist

The items below represent the gap between the current state and a production-grade system.

### Testing

- [ ] **Integration tests** — test each framework end-to-end with mocked LLM calls
- [ ] **Graph topology tests** — verify LangGraph edges produce expected state sequences
- [ ] **Crew output parsing** — test `_apply_result()` extracts artifacts correctly from varied CrewAI responses
- [ ] **AutoGen conversation boundary** — test group chat terminates within max_round, handles tool calls
- [ ] **State persistence** — test `MemorySaver` checkpointing survives process restart
- [ ] **Error injection** — test each failure mode (LLM timeout, tool error, invalid output) per framework

### Reliability

- [ ] **Retry with backoff** — `_build_composite_pipeline()` delegates to sub-crew but lacks timeout-wrapping for the nested call
- [ ] **Graceful degradation** — if CrewAI crew fails mid-sequence, partial artifacts should be preserved
- [ ] **Dead letter state** — define what happens when all retries are exhausted (notify, log, store failed state)
- [ ] **Concurrent execution limits** — CrewAI and AutoGen don't enforce semaphore limits like the legacy `PydanticAIAgentProvider` does

### Observability

- [ ] **Per-node timing** — LangGraph nodes use `recorder.record_span()` but CrewAI/AutoGen bridges batch entire pipeline into one span
- [ ] **Logfire integration** — verify telemetry export works in all frameworks, not just legacy
- [ ] **Token tracking** — CrewAI and AutoGen don't expose `token_usage` like `PydanticAIAgentProvider` does
- [ ] **Structured logging** — all bridge functions should log structured attributes (run_id, stage, agent_count)

### Security

- [ ] **Tool sandboxing** — file read/write tools check path traversal for LangGraph/CrewAI; verify AutoGen tool execution doesn't bypass
- [ ] **Secret injection** — API keys reach Agent models through `settings`; verify no framework exposes keys in logs
- [ ] **Dependency supply chain** — `crewai` and `pyautogen` add significant transitive dependencies; audit for known vulnerabilities

### Performance

- [ ] **Graph compilation overhead** — `StateGraph.compile()` should be cached, not called per execution
- [ ] **MemorySaver persistence** — in-memory checkpointer doesn't survive restart; replace with `SqliteSaver` or `PostgresSaver`
- [ ] **Streaming** — LangGraph supports `astream_events()` for real-time progress; not wired to CLI/MCP output yet
- [ ] **Parallel agent execution** — CrewAI's `Process.hierarchical` runs agents in parallel; verify concurrency limits are enforced

### Configuration

- [ ] **Blueprint schema validation** — BLUEPRINTS dict uses loose typing (`dict[str, str | list[str]]`); validate required fields per framework
- [ ] **Framework telemetry toggle** — `logfire` instrumentation should be disableable per-framework for debugging
- [ ] **Model override per blueprint** — not all blueprints need `deepseek-reasoner`; allow `model_tier` in blueprint config

### Documentation

- [ ] **API reference** — document the `PipelineOrchestrator` protocol and `build_pipeline()` contract
- [ ] **Error code catalog** — list all `FailureReport.error_type` values and their recovery paths
- [ ] **Blueprint authoring guide** — explain how to add a new blueprint with a custom crew or group chat
- [ ] **Migration guide** — steps to migrate from legacy sequential pipeline to LangGraph graph format
