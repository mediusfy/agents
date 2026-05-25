# OpenClaw Agents — Telemetry & Inter-Agent Communication Review

_Scope: review only, no refactors. Severity: **high** / **med** / **low**._
_All citations are `relative/path.py:line` against the tree at `adding_tracing_in_pipelines` (HEAD `001a793`)._

Cross-cutting context:

- Logfire is configured in two places — `main.py:23-36` and `src/openclaw/mcp_server.py:27-44`.
  Only `instrument_pydantic()` + `instrument_httpx()` are wired. **`logfire.instrument_pydantic_ai()`
  is never called and no `Agent(instrument=True)` flag is set on any agent constructor.** This is
  the single largest gap in the current setup.
- A second telemetry path writes `telemetry.jsonl` (`src/openclaw/telemetry.py`). The repo's
  committed `telemetry.jsonl` shows every metadata object is `{}` — i.e. the JSONL channel is
  capturing only `agent_name + duration + success` and nothing else.
- All cross-agent calls go through `AgentRegistry` in `src/openclaw/registry.py` or a direct
  `agent.run(...)` inside `main.py` / `existing_code_handler.py`. There is no message queue,
  no shared mutable context object, no IPC — communication is in-process async calls.

---

## 1. Telemetry / Observability

### 1.1 What's instrumented today

| Surface | Where | What it captures |
|---|---|---|
| Logfire spans | `mcp_server.py:71-83, 114-126, 156-264`, `existing_code_handler.py:54-244`, `registry.py:132` | Tool/stage entry, hand-rolled attributes (`prompt_length`, `capability`, `agent_name`, `codebase_path`, etc.) |
| HTTPX traffic | `mcp_server.py:36`, `main.py:31` (`logfire.instrument_httpx`) | Outbound HTTP. Headers explicitly disabled. |
| Pydantic model validation | `mcp_server.py:35`, `main.py:30` (`logfire.instrument_pydantic`) | Validation events on every pydantic model — note that this fires on `Artifact`, which carries full file content. See 1.2.5. |
| FastAPI | `mcp_server.py:58` (best-effort, gated on `hasattr(mcp, "app")`) | Request spans on the MCP transport. |
| JSONL fallback | `telemetry.py:14-44` | `{agent, duration_sec, success, metadata}` per agent run. |
| Stdlib logging | `logging.basicConfig(level=INFO)` at `main.py:19` and `mcp_server.py:46` | Free-form messages, mostly f-string interpolated. |

### 1.2 Findings

#### 1.2.1 `pydantic-ai` itself is not instrumented — **high**

`Agent` instances in `src/openclaw/agents/*.py` are constructed without `instrument=True`, and
`logfire.instrument_pydantic_ai()` is never called. Examples: `backend.py:68-73`,
`review.py:17-23`, `service_engineer.py:10-46`, `quality_gate.py:48-53`,
`planner_agent.py:16-21`. The repo therefore loses the rich spans that pydantic-ai emits
out of the box — model name, request/response token counts, tool call hierarchy,
retry attempts driven by `retries=…`, and the parent/child relationship between an
agent's run and its `@agent.tool` invocations.

The hand-rolled `logfire.span("mcp.run_agent", …)` wrappers in `mcp_server.py:67-83`
record `request_length` but not the model, not the token counts, not the tool calls
made under the span.

**Fix:** add `logfire.instrument_pydantic_ai()` immediately after `logfire.configure()` in
both `main.py` and `mcp_server.py`. Verify by running one pipeline pass and checking
that each `mcp.run_agent` span has child spans named like `agent.run` / `tool.<name>`.

#### 1.2.2 JSONL telemetry has empty metadata everywhere — **high**

`main.py:68` is the only caller of `telemetry.track(...)` and passes no metadata:

```python
return await telemetry.track(agent_name, _run_with_retry)
```

The signature accepts metadata (`telemetry.py:14`) but `track` (`telemetry.py:30-44`)
hard-codes the `log_call` kwargs to no metadata. Result: every JSONL row has
`"metadata": {}` (verified in the committed `telemetry.jsonl`). Pipeline
attributes that *should* be recorded — `run_id`, `project`, `user_story_id`,
`attempt`, `capability`, `model` — are not.

Per-run JSONL postmortem is essentially impossible: you can see "backend agent
ran 12 times today" but not "which run, which user story, which attempt".

**Fix:** thread `run_id` / `project` / `attempt` / `story_id` down through
`run_agent → telemetry.track → log_call` as an explicit `metadata` dict, and
on the existing-code path do the same in `_run_stage`. `_run_stage` already
passes `span_attrs` to `log_call` (`existing_code_handler.py:69`) — that path
is correct; the SDLC pipeline path is the broken one.

#### 1.2.3 Tenancy / correlation IDs are absent from log lines — **high**

`logger.info(f"BA Agent processing: {raw_requirements}")` (`main.py:73`) and similar
log statements throughout `main.py` and `existing_code_handler.py` are f-string
interpolated, so the `run_id`, `project`, and `attempt` never appear as structured
fields. With two concurrent MCP requests the log file becomes uncorrelatable.

There is also no concept of `tenant_id` at all — fine for a single-user dev tool,
but if this ever serves multiple callers (the MCP path absolutely supports
concurrent calls) you cannot attribute spend or failures to a tenant.

**Fix:** introduce a single `with logfire.span("openclaw.run", run_id=…, project=…)`
around the whole pipeline call (in both `main.main` and each MCP tool entrypoint),
and replace `logger.info(f"…")` with `logfire.info("…", run_id=…)` for the
significant transitions. The cheap alternative is to bind a `LoggerAdapter` once
and reuse it, but logfire kwargs are strictly better.

#### 1.2.4 Token usage and cost are never recorded — **high**

pydantic-ai's `RunResult` exposes `.usage()` with `input_tokens`, `output_tokens`,
`total_tokens`. Nothing in the codebase reads it. Models are configurable per-agent
in `settings.py:35-56` and the resolver routes most things to DeepSeek
(`settings.py:65-98`), so cost-per-run is opaque until your provider bill arrives.

**Fix:** in `run_agent` (`main.py:48-68`), pull `result.usage()` after the await
and attach to both the logfire span and the JSONL metadata. Same in
`_run_stage` (`existing_code_handler.py:53-69`) and `registry.query`
(`registry.py:78-103`).

#### 1.2.5 `instrument_pydantic()` may exfiltrate full file contents — **high**

`Artifact.files` is `dict[str, str]` of file path → full file contents
(`models/core.py:20-30`). With `logfire.instrument_pydantic()` active, every
`Artifact` validation produces a Logfire event including the model field values —
that's every generated Go file, including anything the security agent has not
yet inspected. The runtime contract of the security agent (`security.py:23-30`)
explicitly looks for hardcoded secrets, but they've already been shipped to
Logfire by then. There is also no `logfire.configure(scrubbing=…)` call.

**Fix:** either pass `record="failure"` to `instrument_pydantic()` so only
validation failures are logged, or scrub via `logfire.configure(scrubbing=ScrubbingOptions(...))`
to redact common secret patterns. At minimum, drop `instrument_pydantic()` from
the MCP server which sees the most exposure.

#### 1.2.6 Logfire is initialised twice with subtle drift — **med**

`main.py:23-36` and `mcp_server.py:27-44` are near-duplicates but diverge:
the MCP path also runs `instrument_fastapi` and sets a module-level
`LOGFIRE_ENABLED` flag, the `main.py` path does neither. `mcp_server.run_openclaw_pipeline`
imports and calls `main.main` (`mcp_server.py:162-165`), so when a pipeline
run is kicked off via MCP, `logfire.configure()` runs twice in the same process.
Logfire tolerates re-configure but it's a smell — and any future addition (e.g.
a scrubber) has to be remembered in two places.

**Fix:** extract a single `openclaw/observability.py` module with one `init_logfire()`
function, call it from both entrypoints, idempotent via a module-level flag.

#### 1.2.7 Telemetry silently disabled when credentials missing — **med**

Both init blocks fall through with a `logger.info("…telemetry disabled")` if no
token is present (`main.py:33-36`, `mcp_server.py:39-44`). There's no metric
exported to detect a misconfigured prod deploy. Combined with 1.2.1, a prod
process with a wrong env var produces zero telemetry and won't surface until
someone notices the dashboard is flat.

**Fix:** keep the soft-fail, but add a `logger.warning("LOGFIRE_DISABLED")` path
the alerting layer can pattern-match on, and a `/healthz` field exposing
`logfire_enabled: bool` (the codebase already has `healthcheck.py`, this fits
there).

#### 1.2.8 `tenacity` retries are invisible to telemetry — **med**

`main.py:58-66` wraps each agent run with `tenacity.retry(stop_after_attempt=3, ...)`.
Telemetry is collected via `telemetry.track(agent_name, _run_with_retry)` —
i.e. the entire tenacity block is one tracked call. Intermediate retries
(`TimeoutError`, `ConnectionError`, `OSError`) are never recorded; you see only
the final outcome and the cumulative duration. The Logfire side has the same
shape: only `mcp.run_agent` spans appear; retry attempts are not children of
that span. No `agent_retry_total` counter exists.

**Fix:** add a `before_sleep` callback to tenacity that emits a logfire event
(`logfire.warn("agent.retry", attempt=…, exception_type=…, agent_name=…)`),
and increment a counter. The simpler retrofit: wrap `_run_with_retry`'s inner
coroutine in its own `logfire.span("agent.attempt", attempt_number=…)` so each
attempt is its own span.

#### 1.2.9 Exception swallowing across handoffs erases stack traces — **med**

Several spots catch `Exception as e` and reduce it to a string or `None`,
losing the type and traceback:

- `main.py:152-157` — `run_tagged` returns `None`, downstream filters it out, no traceback logged.
- `main.py:206-207, 231-234, 247-249, 262-265` — `Quality Gate failed: {e}` style; uses `logger.error(...)` not `logger.exception(...)`.
- `mcp_server.py:186-197` — `_run_task` stores `f"ERROR: {e}"` in a results dict and the calling code happily continues; the span closes at `_level="info"` regardless of failure.
- `registry.py:99-103` — `registry.query` catches all exceptions and returns `f"Agent error: {e}"`. The caller cannot tell success from failure.
- `existing_code_handler.py:163-166, 203-206, 241-244` — appends to `result.errors` but doesn't re-raise; the outer caller treats success as the absence of `errors`.

Each of these would benefit from `logger.exception(…)` (so the traceback lands)
and a logfire event with `_level="error"`.

**Fix:** swap `logger.error(...)` for `logger.exception(...)` in those handlers,
and inside the `with logfire.span(...)` blocks set `_level="error"` (or call
`span.set_level("error")` if the API supports it) when an exception is caught.

#### 1.2.10 Print-based logging in `validators.py` and `vector_db.py` — **med**

`validators.py:29-75` uses `print()` for validation outcomes. These bypass
logfire/stdlib logging entirely and are invisible to centralised collection.
`vector_db.py:49` does the same for search failures inside a `try/except`.

**Fix:** convert to `logger.warning(...)` / `logger.error(...)`. Validator
should also emit a span attribute (`go_files_validated`, `failures`) on the
enclosing pipeline span.

#### 1.2.11 Subprocess (`gofmt`) is not span-wrapped — **low**

`service_engineer.py:71-82` runs `gofmt -d filepath` with `timeout=30` and
silently swallows the timeout/exception case (returns `"ERROR: {e}"`). No
Logfire span around the subprocess call, no metric for `gofmt_invocations` or
failures. Cheap to fix.

#### 1.2.12 Hand-rolled spans use `_level="info"` everywhere — **low**

Every `logfire.span(...)` in `mcp_server.py` and `existing_code_handler.py`
sets `_level="info"`. Retry paths, fallback paths, and degraded paths all
look identical to happy-path spans on the UI.

**Fix:** bump retry / fallback paths to `notice` or `warning`. The hand-rolled
span context manager doesn't have to know the outcome — just upgrade level in
the `except` arm.

#### 1.2.13 No span attributes for `model` / `provider` on agent runs — **low**

The MCP `create_agent_runner` (`mcp_server.py:67-83`) opens a span without
recording which model the agent uses. Combined with the `settings.resolve_model`
provider override (`settings.py:65-98`) that re-routes many models to DeepSeek,
operators reading Logfire have no way to know which model actually ran. Adding
`model_name` and `provider` to span attributes is a one-liner.

#### 1.2.14 No rotation / sink discipline on `telemetry.jsonl` — **low**

`telemetry.py:26-28` opens the file in `"a"` mode for every line, no rotation,
no max size. Will grow without bound and is in repo root — easy to accidentally
commit (the file *is* currently in the working tree).

**Fix:** move under `.claw-telemetry/`, gitignore it, and use a rotating handler.



## 2. Inter-Agent Communication

### 2.1 Communication topology

- **Direct in-process calls.** All agent invocations are `await agent.run(...)`
  through pydantic-ai. There is no queue, no IPC, no subprocess boundary.
- **`AgentRegistry` (`src/openclaw/registry.py:18-103`)** is the routing table.
  Agents are looked up by `name` or by `capability`. The first agent registered
  for a capability wins via insert; later registrations overwrite the index entry
  silently (see 2.2.1).
- **Three orchestrators** drive multi-agent flows:
  1. `main.py` — the linear SDLC pipeline (BA → Advisory → Implementation loop → Security → Quality Gate → Review → Write). Per-story fan-out uses `asyncio.gather`.
  2. `existing_code_handler.run_existing_code_pipeline` — surgical change pipeline (service_engineer → test_eng → quality_gate → review). Sequential.
  3. `plan_and_execute` (`mcp_server.py:168-209`) — dynamic plan from `planner_agent`, executed in dependency batches.
- **One sub-agent tool** exposes agent-to-agent delegation from inside an agent: `delegate_to_agent` in `src/openclaw/tools/a2a_tools.py:18-31`.
- **State is shared via `PipelineState`** (`models/core.py:76-83`) which is checkpointed to JSON in `.claw-checkpoints/<project>/<run_id>_<stage>.json`.

### 2.2 Findings

#### 2.2.1 Duplicate capability registrations silently last-write-wins — **high**

`AgentRegistry.register` (`registry.py:24-36`) builds `_cap_index[cap] = name`
without checking for collisions. In `agents/registration.py` the following
capabilities are claimed by multiple agents:

| Capability | Registered by | Final winner (last write) |
|---|---|---|
| `implementation` | `backend:34`, `frontend:35`, `service_engineer:49` | `service_engineer` |
| `finance` | `accountant:64`, `asymmetric_reviewer:68`, `crypto_oracle:74`, `market_shark:84` | `market_shark` |
| `planning` | `planner:51`, `holiday_planner:79` | `holiday_planner` |
| `review` | `review:44`, `quality_gate:47` | `quality_gate` |
| `news` | `current_events:71`, `crypto_oracle:74` | `crypto_oracle` |
| `analysis` | `region_analyzer:72`, `price_analyst:91` | `price_analyst` |

Any caller of `delegate_to_openclaw_agent(capability="implementation", …)` or
`plan_and_execute` where the planner emits `capability: "review"` gets routed
to whichever agent happened to be registered last, with no warning. The
delegation docstring in `mcp_server.py:131-138` advertises capabilities
("backend_dev", "frontend_dev", "infra_advice", etc.) that **don't even exist**
in the index — every one of those is the *agent name*, not a capability.

**Fix:** raise `ValueError` on collision in `register()` (already done for
name collisions at line 33 — apply the same to capabilities). Then either
(a) rename capabilities so each is unique to one agent, or (b) make
`_cap_index[cap]` a list and surface ambiguity to the caller. Also align
the docstring in `delegate_to_openclaw_agent` with reality.

#### 2.2.2 `review_agent` requires deps that the pipeline never supplies — **high**

`review_agent` (`agents/review.py:17-23`) is constructed with
`deps_type=ReviewDependencies` and has a dynamic `@review_agent.system_prompt`
(`review.py:26-54`) that reads `ctx.deps.blueprint_summary` and
`ctx.deps.bounded_contexts`. But the pipeline call at `main.py:260` is

```python
review_res = await run_agent(semaphore, "review", registry.get("review"), review_prompt)
```

no `deps=` argument. In `run_agent` (`main.py:48-68`) the `deps is None` branch
runs `agent.run(prompt)` with no deps. Pydantic-ai will reject the call (deps
type required) or pass `None`, and the dynamic system prompt builder will
`AttributeError` on `ctx.deps.blueprint_summary`. The exception is then
swallowed at `main.py:262-265`:

```python
except Exception as e:
    logger.error(f"Review agent failed: {e}")
    break
```

So the loop breaks, `result` is never assigned, and the implementation stage
returns with no review approval. Net effect: **the Board-of-Review stage in the
SDLC pipeline never actually approves anything** — it either crashes silently
or, if pydantic-ai default-constructs deps, runs against an empty blueprint.
The path that *does* feed deps to a review-type agent is the existing-code
handler's call to `review` (`existing_code_handler.py:224-231`), which also
doesn't pass deps — same problem on that path.

**Fix:** decide whether `ReviewDependencies` is required. If yes, plumb the
blueprint + bounded contexts from BA stage output through `state.advisory_results`
and pass `deps=ReviewDependencies(blueprint_summary=…, bounded_contexts=…)` at
every call site. If no, drop `deps_type` and inline the static prompt.

#### 2.2.3 `registry.query` swallows all exceptions and returns a string — **high**

`registry.py:101-103`:

```python
except Exception as e:
    logger.warning("Agent '%s' failed for capability '%s': %s", agent_name, capability, e)
    return f"Agent error: {e}"
```

The return type is `str`, callers can't distinguish success from failure. This
matters most in `plan_and_execute` (`mcp_server.py:186-198`), which stores the
return value as the task output and continues running downstream tasks that
might depend on it — silently feeding `"Agent error: timeout"` as a "result"
into the next agent's prompt. Same problem for `delegate_to_openclaw_agent`
and the `delegate_to_agent` tool (`tools/a2a_tools.py:18-31`).

**Fix:** raise a typed `AgentExecutionError` (already defined in
`openclaw/exceptions.py:16-21`) and let the orchestrator decide whether to
treat it as a hard fail, store on `task.error`, or retry. Don't pretend a
failure is a result.

#### 2.2.4 `plan_and_execute` has no per-task timeout and no global limit — **high**

`mcp_server.py:186-198`:

```python
async def _run_task(t):
    try:
        result = await instrumented_query(...)
        results[t.id] = result
    except Exception as e:
        results[t.id] = f"ERROR: {e}"

await asyncio.gather(*[_run_task(t) for t in batch])
```

`instrumented_query` is called without `timeout=` (`registry.py:106-112`
accepts it but `plan_and_execute` never passes one). If one LLM call hangs,
the whole batch hangs; if the planner emits a thousand tasks, all thousand
get scheduled. There's no bound on `len(plan.tasks)`, no global timeout for
the `plan_and_execute` MCP call, and no concurrency cap separate from any
per-agent semaphore (the pipeline's `max_concurrent_llm_calls` semaphore in
`main.py:329` does NOT apply here because `plan_and_execute` bypasses
`run_agent` and uses `instrumented_query` directly).

A malicious or buggy planner output can OOM the process or pin LLM tokens.

**Fix:** pass a per-task timeout, cap `len(plan.tasks)` (e.g. 50), and reuse
the same semaphore (move it out of `main.py` into a module-level resource).
Wrap the whole `plan_and_execute` body in `asyncio.wait_for(..., timeout=N)`.

#### 2.2.5 `delegate_to_openclaw_agent` re-registers all agents every call — **high**

`mcp_server.py:130-150`:

```python
async def delegate_to_openclaw_agent(...):
    from openclaw.agents.registration import register_all_agents
    register_all_agents()
    ...
```

`register_all_agents()` calls `registry.register(name, …)` for ~25 agents.
`register()` raises `ValueError("Agent 'X' is already registered.")` on
duplicate (`registry.py:32-33`). The second invocation of this MCP tool
will crash on the first agent registration. Same issue in
`modify_existing_code` (`mcp_server.py:212-246`) which also calls
`register_all_agents()`.

**Fix:** make `register_all_agents` idempotent (early-return if a sentinel
agent is already registered, or change `register` to `register_or_replace`),
or call it once at module import / app startup.

#### 2.2.6 Tenacity retries are not idempotent w.r.t. side-effecting tools — **high**

`main.py:58-66` retries on `TimeoutError`, `ConnectionError`, `OSError`. Many
agents are wired with tool categories that include `memory` and the
`log_activity` tool (`tools/memory.py:14-34`), which writes to a ChromaDB
collection on every significant action. There's also `read_and_memorize_url`
and `read_and_memorize_pdf`. A retried run can re-execute these writes; doc
IDs use `f"log_{pass_num}_{agent_name}_{datetime.datetime.now().timestamp()}"`
which guarantees a new ID on every retry, so duplicates accumulate.

The `Memory.add_memory` path (`memory.py:40-48`) hashes content for the id,
so identical content produces identical ids — but the prefix includes
`memory.timestamp` which is `datetime.now().isoformat()`, refreshed per
retry. So memory writes are *not* idempotent either.

**Fix:** scope retries to only the cases where the agent demonstrably did
not commit any side effect (i.e. the model call itself failed before any
tool dispatched). The cleanest path: don't retry inside `run_agent`; let
pydantic-ai's own `retries=` parameter handle output-schema retries, and
make connection-level retries happen at the HTTP layer (logfire's
instrument_httpx + httpx's `Retry`).

#### 2.2.7 Checkpoint save is not atomic — **med**

`checkpoint.py:23-31`:

```python
with open(filepath, "w") as f:
    f.write(data)
```

A SIGTERM or process kill between the truncate (caused by `"w"`) and the
write completing leaves a zero-length / partial JSON file on disk. On resume,
`load()` catches `JSONDecodeError`, logs a warning, returns `None`, and the
pipeline re-runs the stage (`main.py:340-352, 363-372, 397-405`). That's
the *correct* recovery, but the corrupted file is never deleted from the
checkpoint dir — so `find_latest_run_id` may keep finding it.

**Fix:** write to `f"{filepath}.tmp"`, then `os.replace(tmp, filepath)`. This
is a four-line change.

#### 2.2.8 Implementation stage isn't checkpointed mid-loop — **med**

`main.py:406-415`: the entire implementation stage runs to completion before
`checkpoint_mgr.save("implementation", state)` fires. If the pipeline dies
during, say, the SRE step, the BA + advisory checkpoints survive but every
backend/frontend/database/test artifact already generated is thrown away on
resume. Worse, the retry loop (`max_retries`) means up to two full
implementation passes can run before a checkpoint — that's potentially
hundreds of LLM calls re-executed on resume.

**Fix:** save a checkpoint after each *sub-stage* (per-story fan-out, test,
SRE, security, QG, review). Add per-stage flags on `PipelineState`
(`models/core.py:76-83`) so resume can skip the substages it already
completed.

#### 2.2.9 No schema-drift guard in existing-code handler — **med**

`existing_code_handler.py:159` reads `if hasattr(test_result.output, "files")`
to decide whether to keep the test artifact. If pydantic-ai retries and
returns a `TestOutput` (`test_eng.py:26-27`, which has only a `code` field)
or any other shape, the test artifact is silently dropped — the pipeline
proceeds as if tests were generated. Same pattern would mask any future
schema migration in `Artifact`.

**Fix:** check `isinstance(test_result.output, Artifact)` and treat the
mismatch as a logged error, not a silent fall-through.

#### 2.2.10 No detection of recursive delegation — **med**

The `delegate_to_agent` tool (`tools/a2a_tools.py:18-31`) lets any agent
call any other agent by capability. There's no detection that agent X has
called agent Y which is now calling agent X. With no per-call depth limit
or `delegation_chain` parameter, an LLM-emitted bad plan can recurse until
the event loop runs out of stack or the MCP request times out.

**Fix:** add a `_delegation_depth` contextvar incremented on each call, hard
fail past some N (4 is plenty). Optionally record the chain on the span as
`delegation_chain=["service_engineer","review","service_engineer",…]`.

#### 2.2.11 `PipelineState.attempt` is set once and never updated — **med**

`models/core.py:79`: `attempt: int = 1`. The implementation retry loop
(`main.py:138-272`) iterates `for attempt in range(max_retries)` but never
writes back to `state.attempt`. On resume after a crash mid-retry-loop,
there's no way to know "we already burned 2 of 3 attempts." Resume will
helpfully restart the whole retry loop, doubling the cost ceiling.

**Fix:** update `state.attempt` inside the loop and checkpoint after each
attempt completes.

#### 2.2.12 Per-story implementation runs share mutable `project_state` — **med**

`main.py:145`:

```python
project_state = ProjectState(base_path="/app/default", environment="dev", team_owner="platform-engineering")
```

`project_state` is passed as `deps=` to every backend agent run for every
user story (`main.py:163`). `ProjectState` is a plain dataclass with no
locking. Today the agents don't mutate it — but if any `@agent.tool` mutates
the deps object, concurrent stories would race. There's no documented "deps
are immutable" contract.

Lower severity because no current mutator exists, but it's a foot-gun for
the next change.

**Fix:** freeze with `@dataclass(frozen=True)` or make it a `pydantic.BaseModel`
with `model_config = ConfigDict(frozen=True)`.

#### 2.2.13 `find_latest_run_id` picks files by mtime, not by run grouping — **med**

`checkpoint.py:58-75` lists all `.json` files in the project dir and picks
the most-recently-modified. If two runs were interleaved (e.g. one
foreground, one MCP-driven), and run A wrote a `ba` checkpoint at T+0 and
run B wrote a `review` checkpoint at T+5, then run A resumes and picks up
run B's run_id. The subsequent `stage_exists("ba")` lookup uses run B's
run_id, finds nothing, and reruns from scratch — but every later stage check
happens against run B's surviving checkpoints. Mixed state on resume.

**Fix:** put each run in its own subdirectory (`<project>/<run_id>/<stage>.json`)
so the directory structure encodes the grouping. Alternatively, keep a
`runs.json` index listing run_ids ordered by start time and skipping those
without a complete `ba` checkpoint.

#### 2.2.14 Hidden state in `_initialized` set masks re-application of tools — **low**

`registry.py:51-54` lazily initialises an agent's tools on first `get()` and
records it in `self._initialized`. If `register_all_agents()` ever runs
twice (it can't today because of 2.2.5, but if we fix 2.2.5 idempotently),
the new `Agent` instance won't have its tools applied because the *name*
sits in `_initialized`. Subtle and easy to trip on.

**Fix:** in `register`, also clear `_initialized.discard(name)`; in
`unregister` it already does (line 43).

#### 2.2.15 `plan_and_execute` clips results in the summary — **low**

`mcp_server.py:206-208`:

```python
summary_lines.append(f"  {status} {t.id} ({t.capability}): {t.prompt[:80]}...")
summary_lines.append(f"     → {results.get(t.id, 'no result')[:200]}")
```

Returned outputs are truncated to 200 chars. The full output is held in
`results` only for the lifetime of the function call — nothing is checkpointed.
The caller can't get the unclipped output later.

**Fix:** stash the full `results` dict to a file under the project checkpoint
dir, and reference it from the summary.

#### 2.2.16 No retry budget on review/security after a quality-gate retry — **low**

`main.py:243-249`: when the quality gate fails, the loop `continue`s — which
re-runs the *entire* implementation phase (backend+frontend+database+devops
+docs+test+SRE+validation+security), not just the quality gate. With
`max_retries=2` (the default in `settings.py:60`) and a stable quality-gate
failure, that's two full cost-heavy passes.

**Fix:** isolate the review/qg retries from the implementation work — only
re-run downstream of the failed gate, or pass the gate feedback back as
deps to the relevant agent (`state_feedback` is already collected at
`main.py:245` but only fed into the *review* prompt at line 257, not back
into backend/frontend/etc).



## 3. Quick wins (top 5 by ROI)

Ranked by `(impact_unlocked) / (lines_changed)`. Each is a few-hour change, no
architectural shift.

1. **Turn on `logfire.instrument_pydantic_ai()` (1.2.1).** One line in
   each of `main.py` and `mcp_server.py` (or one line in a shared
   `observability.init()` once 1.2.6 is also done). Unlocks model name, token
   counts, tool-call hierarchy, and pydantic-ai's own retry spans for every
   agent — without touching any agent constructor. Also closes part of 1.2.4
   (token usage) for free.

2. **Fix duplicate capability registration (2.2.1).** Three-line change in
   `registry.py:24-36` to raise on collision, plus an audit of
   `agents/registration.py:32-92` to deduplicate. Eliminates the entire class
   of "silently routed to the wrong agent" failures, which today affect
   `implementation`, `finance`, `planning`, `review`, `news`, and `analysis`.

3. **Fix `review_agent` deps wiring (2.2.2).** Either drop `deps_type` and
   inline a static prompt, or thread `ReviewDependencies` from BA output
   through `state` to the two call sites (`main.py:260` and
   `existing_code_handler.py:224-231`). The review stage today silently
   no-ops or silently crashes; making it actually run is required before any
   future telemetry on it is meaningful.

4. **Thread `run_id`/`project`/`story_id`/`attempt` into `telemetry.track`
   and span attributes (1.2.2 + 1.2.3).** A pair of `metadata=` keyword
   arguments at `main.py:68` and a wrapping `logfire.span("openclaw.run",
   run_id=…)` at the top of `main.main` and each MCP tool. Cost: ~15 lines.
   Unlocks per-run JSONL postmortem and per-run Logfire filtering — currently
   impossible.

5. **Make checkpoint save atomic (2.2.7).** Replace the
   `open(filepath, "w") + write` in `checkpoint.py:23-31` with a
   tmp-file + `os.replace` pattern. Six-line change. Eliminates the corrupted-
   checkpoint failure mode on SIGTERM/OOM and the "stale corrupted file
   confuses `find_latest_run_id`" follow-on.

Honourable mention (slightly larger but huge win): **make
`register_all_agents()` idempotent (2.2.5).** Today the second call to
`delegate_to_openclaw_agent` or `modify_existing_code` from the same MCP
process *crashes*. This is almost certainly already biting users.

---

## 4. Architecture Verdict — ADR-001 (post-fix design)

**Status:** Proposed
**Date:** 2026-05-25
**Deciders:** repo owner

This section is structured as an Architecture Decision Record evaluating the
intended (post-quick-wins) shape of OpenClaw against four framing questions.
It assumes the §3 quick wins are applied; the goal here is to decide whether
the resulting architecture is sound or needs a deeper restructure.

### Context

OpenClaw is a multi-agent SDLC pipeline built on `pydantic-ai`, exposed to AI
runtimes (Claude Desktop, Claude Code, Hermes, plus the project's own
`main.py` CLI and a stubbed `opencode.json` runtime) over an MCP stdio
server. Each runtime invocation spawns its own `mcp_run.sh` child process
(`mcp_run.sh:1-15`) which boots a fresh `FastMCP` instance, its own
`AgentRegistry`, and shares `.claw-checkpoints/<project>/` on disk with
every other concurrent process pointing at the same repo.

Three orchestration shapes coexist:

- **Linear pipeline** in [main.py:48-274](main.py:48) — BA → Advisory → Implementation
  (with per-story `asyncio.gather` fan-out) → Security → Quality Gate → Review.
- **Sequential chain** in [existing_code_handler.py:72-247](src/openclaw/existing_code_handler.py:72) —
  service_engineer → test_eng → quality_gate → review.
- **Dependency-batched DAG** in [mcp_server.py:181-209](src/openclaw/mcp_server.py:181) —
  `plan_and_execute` runs `plan.tasks` in waves whose membership is determined
  by `all(dep in completed for dep in t.dependencies)`.

State is checkpointed as JSON files; agents are registered in an in-process
dict; cross-agent calls go through `registry.query` or a directly-imported
sub-agent's `.run()`.

### Decisions

#### Q1. In-process pydantic-ai for a multi-runtime caller — **Accept with constraints**

The current model — one MCP child process per caller, agents instantiated in
process, no shared daemon — is the right shape for OpenClaw's *current*
single-user, single-machine use case. The complexity of a long-running shared
daemon (auth, fairness, quotas, supervision) is not warranted yet.

However the model only works **if concurrent runs against the same project
are forbidden**. Today they are not, and the shared `.claw-checkpoints/`
directory plus the lock-free `find_latest_run_id` ([checkpoint.py:58-75](src/openclaw/checkpoint.py:58))
make two concurrent runs against `project=default` corrupt each other.

**Decision:** keep in-process; add a `pipeline.lock` file (an `fcntl.flock`
on `<checkpoint_dir>/<project>/.lock`) acquired for the duration of
`main.main` and each MCP tool that mutates state. Document the contract as
"per-caller MCP child, single concurrent pipeline per project".

**Alternative considered — long-running daemon with a queue:** rejected.
Adds two new failure surfaces (supervision, queue durability) without solving
a problem any caller currently has. Revisit when:
- multiple users hit one openclaw, OR
- pipelines need to span machine reboots, OR
- you need cross-runtime observability of in-flight work.

#### Q2. JSON-file checkpoints vs durable queue — **Accept JSON; fix granularity and layout**

The format (JSON files) is not the bottleneck. The real problems are:

- **Granularity:** [main.py:413-415](main.py:413) checkpoints once *per phase*. An
  implementation phase can run hundreds of LLM calls; SIGTERM mid-phase
  throws all of them away on resume.
- **Atomicity:** [checkpoint.py:23-31](src/openclaw/checkpoint.py:23) opens with `"w"` (truncates)
  then writes. Crash mid-write leaves a zero-length file that
  `find_latest_run_id` happily picks up.
- **Run grouping:** filenames are `<run_id>_<stage>.json` in a flat per-project
  dir. Two interleaved runs share the directory; `find_latest_run_id` picks
  by mtime, not by run cohesion.

**Decision:** keep JSON. Make three changes — already covered in §3 (atomic
write) plus two more:
1. Move to `<project>/<run_id>/<stage>.json` so each run is its own directory.
2. Checkpoint after each sub-stage inside `run_implementation_stage`
   (per-story gather, test, SRE, security, QG, review). Add per-substage
   flags on `PipelineState` so resume skips what's already done.

**Alternative considered — SQLite-WAL or Redis queue:** rejected as
premature. SQLite-WAL would be the natural upgrade if you later need
cross-process safety; the migration is straightforward because
`PipelineState` is already a pydantic model. Defer until needed.

#### Q3. `AgentRegistry` vs a service bus — **Accept registry; widen capability mapping; add audit hook**

The current `AgentRegistry` is a dict-backed lookup over ~25 agents. Its
strengths (zero ops, debuggable, type-checked deps factories) match
OpenClaw's scale. Its weaknesses are real but local:

- `_cap_index: dict[str, str]` ([registry.py:21](src/openclaw/registry.py:21)) is 1:1, so capability
  collisions silently last-write-win (finding 2.2.1).
- `registry.query` swallows exceptions into strings (2.2.3).
- No audit / per-call hook surface — instrumentation has to be bolted on at
  the caller (see `instrumented_query` in [registry.py:106-139](src/openclaw/registry.py:106)).
- No remoting — every agent must be importable in the caller's process.

A pub/sub bus (NATS, Redis Streams) would address remoting + fanout + audit
but introduces three new failure modes the system doesn't have today:
serialization, broker availability, delivery semantics. None of OpenClaw's
current callers need any of those.

**Decision:** keep `AgentRegistry`. Change three things:
1. `_cap_index: dict[str, list[str]]`, with an explicit routing policy
   (priority-ordered list, first one wins; collisions logged at registration
   time, not silently). Allows e.g. `"finance"` to legitimately resolve to
   multiple agents and the caller picks.
2. `registry.query` raises typed exceptions (`AgentNotFoundError`,
   `AgentTimeoutError`, `AgentExecutionError` — all defined in
   [exceptions.py:12-22](src/openclaw/exceptions.py:12) and unused).
3. Add a `register_call_hook(fn)` API so `instrumented_query`'s span +
   telemetry logic moves *into* the registry instead of being a separate
   wrapper. This eliminates the foot-gun in [a2a_tools.py:31](src/openclaw/tools/a2a_tools.py:31) where
   `delegate_to_agent` bypasses `instrumented_query` and silently drops
   spans.

**Alternative considered — NATS/JetStream subject-routed agents:** rejected
for the reasons in Q1. Worth a second look only if openclaw becomes a
multi-tenant service.

#### Q4. Linear pipeline vs DAG — **Migrate `main.py` onto the same wave executor as `plan_and_execute`**

This is the only "real" architectural decision in the set. The other three
are "keep what you have and patch the edges." This one would change the
shape of the system.

Today three orchestration shapes coexist. Each is hand-rolled, each has its
own retry policy, its own error handling, its own telemetry placement. The
linear pipeline in `main.py` hard-codes assumptions that aren't true:

- **Security can run in parallel with Implementation.** Today it runs
  serially after the implementation phase ([main.py:220-235](main.py:220)). The
  static security audit ([security.py:51-57](src/openclaw/agents/security.py:51)) does not depend on
  test results; it can run as soon as artifacts exist.
- **Quality Gate can run per-artifact, not per-batch.** Today the QG sees
  the formatted bundle ([main.py:240-242](main.py:240)). A per-artifact QG
  would localise failures and let the loop replan only the failed pieces
  instead of re-running everything.
- **Review is the only true sync point.** It's the only stage that needs
  the union of all upstream outputs.

The wave executor in [mcp_server.py:181-198](src/openclaw/mcp_server.py:181) already implements
dependency-batched task execution — exactly what a pipeline DAG needs. The
linear pipeline could be expressed as a `Plan` with explicit `dependencies`
and run through the same executor.

**Decision:** in a follow-up phase (not now), refactor `main.py`'s pipeline
to a static `Plan` declared at module level, executed via a hardened version
of `plan_and_execute`'s wave loop. Benefits:

- One control-flow shape, one retry policy, one telemetry placement.
- Per-stage checkpoints fall out for free (each task is a checkpoint unit).
- Security / QG / Review parallelism becomes a declarative dependency edge.
- The MCP tools `run_openclaw_pipeline` and `plan_and_execute` collapse onto
  the same primitive.

**Costs:**
- `main.py` becomes harder to read top-to-bottom. The current linear shape
  is genuinely a teaching tool.
- The wave executor needs hardening first (per-task timeout, fan-out cap,
  shared semaphore — all called out in 2.2.4 / 2.2.5).

**Order-of-operations:** harden the wave executor (§3 + 2.2.4/2.2.5), then
migrate. Don't migrate onto a buggy executor.

### Trade-off summary

| Question | Verdict | Why |
|---|---|---|
| Q1 — in-process topology | Keep + add lock | Right for current scale; concurrency bug is the only blocker. |
| Q2 — JSON checkpoints | Keep + atomic + per-run dirs + finer granularity | Format isn't the bottleneck; granularity and layout are. |
| Q3 — `AgentRegistry` | Keep + widen capability map + audit hook | Bus would add three failure modes for no current benefit. |
| Q4 — linear vs DAG | Migrate (deferred) | Resolves three-shape duplication; unlocks security/QG parallelism. |

### Consequences

**Easier after these changes:**
- Two MCP callers can hit the same project without corrupting state.
- A crashed implementation phase resumes from the last sub-stage.
- A capability lookup either resolves to a known list or fails loudly at
  registration time — no more silent mis-routing.
- All cross-agent calls (including `delegate_to_agent` inside an agent
  tool) carry the same telemetry shape.

**Harder after these changes:**
- Anyone reading `checkpoint.py` has to think about the run-dir layout.
- The registry's capability API has a routing-policy concept the caller has
  to pick.
- Eventually (Q4), `main.py` is no longer a line-by-line tour of the
  pipeline.

**Revisit when:**
- A second user shares an openclaw instance.
- A pipeline needs to survive process restart.
- A caller wants to subscribe to "any agent completed" events.

### Action items (this evaluation only — not in §3)

1. [ ] **(Q1)** `fcntl.flock` on `<checkpoint_dir>/<project>/.lock` in
   `main.main` and every state-mutating MCP tool.
2. [ ] **(Q2)** Per-run checkpoint subdirectory + sub-stage save points in
   `run_implementation_stage`.
3. [ ] **(Q3)** Capability list mapping + typed exceptions out of
   `registry.query` + call-hook API.
4. [ ] **(Q4 — deferred)** Migrate `main.py` orchestration onto the wave
   executor; harden the executor (timeout / fan-out cap / shared
   semaphore) first.

---

## 5. Design Critique — MCP tool surface as UX

The "user" of the openclaw MCP server is another AI runtime (Claude Code,
Hermes, Claude Desktop, opencode, and openclaw's own `delegate_to_agent`
tool). UX heuristics — hierarchy, consistency, perceived control, error
visibility — translate directly. Findings are ordered by impact.

### 5.1 First impression — the tool menu mixes unrelated domains — 🔴 Critical

The tool list registered in [mcp_server.py:88-265](src/openclaw/mcp_server.py:88)
mixes two unrelated product surfaces in a single MCP namespace:

- **SDLC orchestration:** `delegate_to_openclaw_agent`,
  `run_openclaw_pipeline`, `plan_and_execute`, `modify_existing_code`,
  `scaffold_and_build_service`, `search_adrs`, `save_adr`.
- **Travel & personal-finance toys:** `run_holiday_planner`,
  `run_region_analyzer`, `run_asymmetric_reviewer`, `run_current_events`,
  `run_weather`, `run_accountant`.

A caller (Claude Code in a Go-services repo) asking the MCP "what can you
do?" gets a list where `run_weather` sits next to `modify_existing_code`.
The cognitive load to pick the right tool is high, and the semantic
juxtaposition undermines trust in the SDLC tools.

**Recommendation:** split into two MCP servers (`openclaw-sdlc` and
`openclaw-personal`), or at minimum prefix tool names by domain
(`sdlc.modify_existing_code`, `personal.weather`). The current
`openclaw-agents` namespace name implies a single concern; the tool list
betrays that.

### 5.2 `delegate_to_openclaw_agent` docstring advertises capabilities that don't exist — 🔴 Critical

[mcp_server.py:131-138](src/openclaw/mcp_server.py:131) docstring:

> Available capabilities: 'requirements_analysis', 'arch_review', 'backend_dev', 'frontend_dev', 'infra_advice', 'db_schema', 'service_engineer' (existing code mods, use modify_existing_code tool instead), 'go_test' (Go table-driven tests), 'quality_gate' (over-engineering check), etc.

The actual registered capabilities ([registration.py:32-51](src/openclaw/agents/registration.py:32))
are: `ba`, `requirements`, `cto`, `architecture`, `advisory`, `backend`,
`implementation`, `frontend`, `database`, `db_schema`, `migrations`,
`devops`, `ci_cd`, `deployment`, `docs`, `documentation`, `sre`,
`infrastructure`, `test`, `testing`, `test_gen`, `go_test`, `review`,
`code_review`, `security`, `audit`, `ux`, `design`, `quality_gate`,
`service_engineer`, `existing_code`, `plan`, `planning`.

`requirements_analysis`, `arch_review`, `backend_dev`, `frontend_dev`,
`infra_advice` — **none exist**. A caller that trusts the docstring sees
"No agent found for capability 'backend_dev'" and has no way to recover
without reading source.

**Recommendation:** make the docstring authoritative. Either generate it
from `registration.py`'s canonical list at import time, or drop the list
and add a `list_capabilities()` MCP tool that returns the live set.

### 5.3 Two tools do the same thing — `run_openclaw_pipeline` and `scaffold_and_build_service` — 🟡 Moderate

[mcp_server.py:153-165](src/openclaw/mcp_server.py:153) and
[:249-265](src/openclaw/mcp_server.py:249) both call `main.main(project=…,
step="all", resume=False, auto_yes=True, requirement=…)`. The only
differences:

- `scaffold_and_build_service` takes a `bounded_context` parameter that is
  embedded into a default requirement string but otherwise unused.
- `scaffold_and_build_service` has slightly different docstring wording.

A caller has to read the source to know they're equivalent. The principle
of least surprise says identical behavior should have one entry point.

**Recommendation:** keep `run_openclaw_pipeline` as the canonical tool;
remove `scaffold_and_build_service` or make it a thin convenience wrapper
documented as such.

### 5.4 `modify_existing_code` advertises auto-detect that doesn't exist — 🟡 Moderate

[mcp_server.py:213-225](src/openclaw/mcp_server.py:213) docstring:

> codebase_path: Path to the existing codebase root. Leave empty to auto-detect.

But [existing_code_handler.py:78-91](src/openclaw/existing_code_handler.py:78)
takes `codebase_path: str` and does no auto-detection — the prompt at
[:108](src/openclaw/existing_code_handler.py:108) just interpolates whatever was passed:

```python
f"Modify the codebase at {codebase_path} to implement this change:\n\n…"
```

If the caller follows the docstring and passes `""`, the agent gets
`"Modify the codebase at  to implement this change"` — likely confusion
or fabricated paths.

**Recommendation:** either implement auto-detect (walk up from CWD looking
for `go.mod` / `package.json`) or drop "leave empty to auto-detect" and
require the path.

### 5.5 Every long-running tool is opaque mid-flight — 🟡 Moderate

`run_openclaw_pipeline`, `plan_and_execute`, `modify_existing_code`, and
`scaffold_and_build_service` all run for minutes (12+ agent calls with
retries). The MCP request/response model means the caller waits for a
single string. There is no:

- `get_pipeline_status(run_id)` tool to poll progress.
- `list_active_runs()` tool to discover what's in flight.
- `get_artifacts(run_id)` tool to inspect partial work.
- Streaming progress (MCP supports notifications, but openclaw doesn't emit
  any).

The checkpoint files at `.claw-checkpoints/<project>/<run_id>_<stage>.json`
hold exactly the data a status tool would surface — it's just not exposed.

**Recommendation:** add a `get_pipeline_status(project, run_id?)` tool that
reads the checkpoint files and reports `{stage, completed_substages,
artifacts_so_far, last_error}`. Cheap to implement (the loader exists in
[checkpoint.py:33-46](src/openclaw/checkpoint.py:33)) and dramatically
improves perceived control.

### 5.6 Error feedback is unstructured prose mixed with success output — 🟡 Moderate

Tool outputs today:

- `delegate_to_openclaw_agent` → returns `registry.query` result, which can
  be `"No agent found for capability 'X'"`, `"Agent error: timeout"`, or a
  real model output. **All have the same type (str), all look the same to
  the caller.**
- `plan_and_execute` → markdown summary with `✓` / `✗` driven by
  substring-match on `"ERROR"` ([mcp_server.py:205](src/openclaw/mcp_server.py:205))
  — a successful agent output containing the word "error" gets misclassified.
- `run_openclaw_pipeline` → one line `"Pipeline completed for X. Artifacts
  written to disk."` even if review rejected, even if zero files were written.
- `modify_existing_code` → `format_result_summary`, which is human-readable
  but mixes status, file list, and feedback in flowing markdown.

A caller AI cannot parse "did this succeed" from any of these without LLM
interpretation of the text.

**Recommendation:** MCP supports structured output. Return JSON-shaped
payloads: `{status: "ok"|"failed", artifacts: [...], errors: [...],
artifact_dir: "..."}`. Reserve markdown for *additional* human-readable
fields.

### 5.7 The capability vocabulary has no namespacing — 🟡 Moderate

Capabilities like `finance`, `news`, `analysis`, `review`, `planning`,
`implementation` are flat strings shared across agents. `"finance"` is
claimed by `accountant`, `asymmetric_reviewer`, `crypto_oracle`, and
`market_shark` (the collision bug from 2.2.1). Even *after* §3 fixes that
collision, a caller still has to know which `finance` they want.

Existing conventions in other MCP servers (e.g. `engineering:*`,
`design:*`, `personal:*`) suggest a prefix policy.

**Recommendation:** namespace capabilities — `personal.finance.accountant`,
`sdlc.review.security`, `sdlc.review.quality_gate`. The 1:1 mapping then
holds naturally and the discovery experience is hierarchical.

### 5.8 Tool inputs are uniformly free-form strings — 🟢 Minor

Every MCP tool takes `str` parameters. No structured inputs (lists,
enums, file paths with validation). The caller AI has to encode all
structure into prose.

For some tools this is fine (`run_holiday_planner(request: str)`). For
others it leaks contract obligations into prompt-engineering: e.g.
`save_adr(decision_id: str, content: str)` doesn't enforce
`decision_id` format ([mcp_server.py:121-126](src/openclaw/mcp_server.py:121));
the BA agent's contract says IDs follow `BC-NN`
([agents/ba.py:16](src/openclaw/agents/ba.py:16)) but `save_adr` accepts
anything.

**Recommendation:** for tools with real input structure (`save_adr`,
`delegate_to_openclaw_agent`, `modify_existing_code`), use pydantic models
as MCP tool parameters. FastMCP supports this directly. The MCP client
gets a schema, validation happens up front, and bad inputs fail at the
boundary instead of inside an agent.

### 5.9 What works well

- **The `create_agent_runner` factory** ([mcp_server.py:67-83](src/openclaw/mcp_server.py:67))
  is the cleanest part of the design: every travel/finance agent gets the
  same wrapper shape (single span, single string in, single string out)
  with zero per-agent boilerplate. The SDLC tools would benefit from the
  same factory.
- **`with logfire.span(...)` at every MCP entry point** is the right
  default. The hard work is making the spans informative (covered in §1).
- **The `defer_model_check=True` pattern** on every agent constructor lets
  the registry start up without API keys, surfacing failures at runtime
  via the healthcheck rather than import time. Good for `--dry-run`.
- **The healthcheck module** ([healthcheck.py](src/openclaw/healthcheck.py))
  exists at all. Most MCP servers don't bother. The MCP tools should
  *expose* it (`healthcheck()` as an MCP tool) so callers can self-diagnose.

### 5.10 Priority recommendations

1. **5.2 + 5.7** — fix the docstring lies and namespace capabilities.
   Without this, every caller's first interaction with `delegate_to_*`
   fails on a typo it can't predict.
2. **5.6** — return structured `{status, artifacts, errors}` from
   long-running tools. Unblocks programmatic chaining by AI callers.
3. **5.5** — add `get_pipeline_status` / `list_active_runs`. Lets a caller
   re-attach to an in-flight run after a connection drop.
4. **5.1** — split the SDLC and personal-toolbox tool surfaces.
5. **5.3 + 5.4** — collapse the duplicate pipeline tool and either
   implement or remove the auto-detect promise.

---

## 6. System Conventions Audit

The `design:design-system` skill is built for UI design tokens / components,
which don't translate. The closest useful adaptation is auditing the
*code-level* conventions that play the same role: naming, error types,
telemetry attributes, and output schemas. Findings below are the
verifiable inconsistencies in `src/openclaw/`.

### 6.1 Summary

| Convention | Status |
|---|---|
| `Agent(... defer_model_check=True)` on every agent | ✅ 29/29 |
| Model spec via `settings.resolve_model(settings.<name>_model)` | ✅ 21/21 settings; the remaining 8 agents intentionally reuse a peer's model |
| `output_type=` on every agent | ✅ universal |
| `retries=N` on agent constructor | ⚠️ Only `review_agent` (`review.py:21`). 28 others rely on the default. |
| Use of `openclaw.exceptions.*` typed errors | ❌ Only `PathTraversalError` is used. The other 7 classes are dead code. |
| Tool category vocabulary | ⚠️ No taxonomy — see 6.4 |
| Settings env-var naming (`<agent>_model`) | ✅ Internally consistent |

### 6.2 Agent constructor — `retries` is the only inconsistency — 🟡 Moderate

Every agent uses the same constructor shape:

```python
agent = Agent(
    create_model(settings.resolve_model(settings.<x>_model)),
    system_prompt=…,
    output_type=…,
    deps_type=… (when needed),
    defer_model_check=True,
)
```

The single divergence is `retries=3` on `review_agent`
([review.py:17-23](src/openclaw/agents/review.py:17)) — added because
`ReviewResult` has nested validation that can flake. The reasoning is sound
but undocumented and inconsistent: agents with comparably nested outputs
(`SecurityReport`, `QualityGateResult`, `AgentAdvice`, the BA agent's
`list[UserStory]` with nested `EventTrigger`) get the pydantic-ai default
(1).

**Recommendation:** establish a convention. Either:
- Every agent with a non-trivial structured output gets `retries=2-3`, OR
- Drop `retries=3` from `review_agent` and document that callers handle
  retry at a higher layer.

The first option is safer for LLM flakiness; pair it with a comment on
the constructor explaining why.

### 6.3 Exception hierarchy is dead code — 🟡 Moderate

[exceptions.py:1-42](src/openclaw/exceptions.py:1) defines a clean
hierarchy: `OpenClawError → ConfigurationError, AgentNotFoundError,
AgentExecutionError, PipelineError → PipelineStepFailedError,
ValidationError, CheckpointError, PathTraversalError`.

A grep for usage across `src/`:

| Class | Used? |
|---|---|
| `PathTraversalError` | ✅ raised in [utils.py:14](src/openclaw/utils.py:14) |
| `OpenClawError`, `ConfigurationError`, `AgentNotFoundError`, `AgentExecutionError`, `PipelineError`, `PipelineStepFailedError`, `ValidationError`, `CheckpointError` | ❌ never raised, never caught |

Every place that *should* raise one of these — `registry.query` on missing
capability, `registry.query` on timeout, `checkpoint.load` on
JSONDecodeError, `validators.run_all_async` on a missing package
declaration — instead returns a string or `None`. The dead exception
classes are a phantom contract: a reader assumes the system uses them and
trusts errors will be typed; the code doesn't deliver.

**Recommendation:** wire them up where the prior review's findings already
demand error-as-exception (2.2.3, 2.2.4, 1.2.9). At minimum:

- `registry.query` raises `AgentNotFoundError` / `AgentExecutionError`.
- `checkpoint.load` raises `CheckpointError(filename, original)`.
- `healthcheck.assert_startup_checks` raises `ConfigurationError` when any
  check fails (today it only warns — see 6.7).

Otherwise, delete the unused classes so the file stops over-promising.

### 6.4 Tool category vocabulary has no taxonomy — 🟡 Moderate

Categories are flat strings registered in [tools/registry.py:15](src/openclaw/tools/registry.py:15)
and assigned by [tool_assignments.py:1-24](src/openclaw/tool_assignments.py:1).
Observed vocabulary mixes three concerns:

| Concern | Examples |
|---|---|
| **Capability domain** | `memory`, `search`, `security`, `validation`, `deps`, `web`, `documentation`, `a2a`, `planning`, `pricing`, `governance` |
| **Agent name aliases** | `backend`, `frontend`, `devops`, `sre`, `docs`, `test`, `code_review` |
| **Domain topics** | `finance`, `crypto`, `stocks`, `investing`, `news`, `research`, `history`, `weather` |

[tools/registry.py:23](src/openclaw/tools/registry.py:23) routes tools to
agents by category overlap OR by agent name:

```python
if any(cat in tool_def.categories for cat in categories) or agent_name in tool_def.categories:
```

So a tool registered with category `["backend"]` is delivered to the
`backend` agent *only because the agent's name happens to match a
category*. There's no schema enforcement that "backend" is a category
worth declaring.

The practical consequence: a new agent registered tomorrow with
`tool_assignments["my_new_agent"] = ["web", "search"]` silently inherits
every tool tagged `web` or `search` — even ones that may not be safe for
that agent (e.g. `read_and_memorize_pdf` for an agent that shouldn't
modify the knowledge base).

**Recommendation:** enumerate the vocabulary. Define an `enum` (or a
literal set) `ToolCategory = Literal["memory", "search", "web", ...]`.
`register_tool` and `tool_assignments` both validate against it. New
categories require a code change, not a typo.

### 6.5 Settings — model env vars are consistent, everything else isn't — 🟢 Minor

Model env vars all follow `<agent>_model: str = "<default>"`
([settings.py:34-56](src/openclaw/settings.py:34)). 21 settings, 21
references. The agents that don't have a dedicated setting reuse a peer's
explicitly:

| Agent | Reuses |
|---|---|
| `quality_gate_agent` | `settings.review_model` |
| `planner_agent` | `settings.cto_model` |
| `service_engineer_agent` | `settings.backend_model` |
| `test_eng_agent`, `test_gen`, `go_test_agent` | `settings.test_model` |
| `extractor`, `event_mapper` (in ba.py) | `settings.ba_model` |
| `component_gen` (in frontend.py) | `settings.frontend_model` |

That's intentional reuse, but undocumented; a reader has to find each
constructor to know `quality_gate` will swap models when `review_model`
changes. Cheap fix: add a `# reuses settings.review_model` comment at the
constructor, or rename the setting to `settings.review_quality_model`
when it's truly shared.

The Redis settings ([settings.py:30-32](src/openclaw/settings.py:30)) and
the cloud-budget defaults in `OrgContext` ([cto.py:14](src/openclaw/agents/cto.py:14))
are hardcoded magic numbers (`monthly_cloud_budget=1000.0`, hardcoded
tech_stack `["Go", "Vue", "PostgreSQL", "Redis"]` at
[main.py:102](main.py:102)) — these belong in settings, not in code.

### 6.6 `dataclass` vs `pydantic.BaseModel` for deps types — 🟢 Minor

Deps types are split between two flavors:

| Type | Used by |
|---|---|
| `@dataclass` | `OrgContext` ([cto.py:11](src/openclaw/agents/cto.py:11)), `ProjectState` ([backend.py:11](src/openclaw/agents/backend.py:11)), `ReviewDependencies` ([review.py:11](src/openclaw/agents/review.py:11)), `SecurityDeps` ([security.py:11](src/openclaw/agents/security.py:11)), `DevopsDeps` ([devops.py:11](src/openclaw/agents/devops.py:11)), `DatabaseDeps` ([database.py:11](src/openclaw/agents/database.py:11)) |
| `pydantic.BaseModel` | `Memory` ([memory.py:30](src/openclaw/memory.py:30)), `ActivityLog` ([models/core.py:61](src/openclaw/models/core.py:61)), output models |

`@dataclass` deps is fine for pydantic-ai (the type is informational at
runtime), but it means deps types don't get validation. If review_agent
were ever passed a `ReviewDependencies(strict_mode="yes")` from a
string-typed source, it'd silently coerce instead of erroring.

**Recommendation:** make deps types `pydantic.BaseModel` (or
`pydantic.dataclasses.dataclass` if you prefer the dataclass syntax) so
validation runs on construction. This is a 6-line change per agent and
catches the kind of contract drift that 2.2.6 / 2.2.11 already warn about.

### 6.7 Healthcheck never fails the boot — 🟢 Minor

[healthcheck.py:74-81](src/openclaw/healthcheck.py:74) declares
`assert_startup_checks` but logs warnings and returns; it never raises.
`main.main` calls it ([main.py:307-308](main.py:307)) without checking the
return value. So a placeholder `OPENAI_API_KEY=sk-...` passes "startup
checks" with a warning that scrolls past on the way to the LLM call that
rejects the placeholder.

**Recommendation:** rename to `run_startup_checks` (already exists) and
have `main.main` actually exit non-zero on a hard failure. The
soft-warning path is fine for "no Logfire token" but wrong for "no usable
API key at all."

### 6.8 Convention coverage scorecard

| Convention area | Score | Top action |
|---|---|---|
| Agent constructor shape | 9/10 | Decide `retries` convention |
| Output schemas | 8/10 | (covered separately in §1/§2) |
| Exception hierarchy | 2/10 | Use the classes or delete them |
| Tool category vocabulary | 4/10 | Enumerate; validate at registration |
| Settings naming | 8/10 | Document reused models |
| Deps types | 6/10 | Migrate to pydantic for validation |
| Healthcheck enforcement | 4/10 | Make hard failures exit |

---

## 7. Design Verdict — Is the design sound?

Synthesis of §4 (Architecture), §5 (MCP UX), §6 (System Conventions).

### 7.1 Headline

**The design is sound at its current scale but has a soft middle.** The
foundational choices — in-process pydantic-ai, MCP stdio servers per
caller, JSON-file checkpoints, an `AgentRegistry` over a service bus —
are correct for a personal/single-machine multi-agent toolbox. None of
them need to be ripped out. The problems are concentrated in three areas
of **finish**:

1. The cross-boundary contracts (capability vocabulary, error types,
   tool-call payloads) are partially-specified, so callers can't program
   against them confidently.
2. The pipeline orchestration has three different control-flow shapes
   (`main.py` linear, `existing_code_handler` chain, `plan_and_execute`
   DAG) when one would do.
3. The "designed but unused" parts (typed exception hierarchy,
   `instrument_pydantic_ai()` not turned on, healthcheck that never
   fails, dead-code capabilities in docstrings) all point to a system
   that was scaffolded richly and then half-wired.

### 7.2 What is sound, keep as-is

- **In-process MCP server per caller**, with the pydantic-ai
  `AgentRegistry` as the primary dispatcher. This matches the scale
  (single user, single machine, multiple AI runtimes) and stays out of
  ops trouble.
- **JSON-file checkpoints**, once granularity + atomicity + per-run dirs
  are fixed (§4 Q2).
- **Constructor consistency** across the 29 agents (one shape, one
  factory function `create_model`/`resolve_model`, `defer_model_check`
  universal). This is the part of the design that scales linearly with
  new agents.
- **The `create_agent_runner` factory** in
  [mcp_server.py:67-83](src/openclaw/mcp_server.py:67) — clean,
  consistent, instrumented. It should be the model for *all* MCP tool
  registrations.
- **Layered structure** — `agents/` for behavior, `tools/` for
  capabilities, `models/` for schemas, `registry.py` for dispatch,
  `checkpoint.py` for state. The decomposition is right.

### 7.3 What is not sound, must change before scale

1. **Three orchestration shapes.** Pick one (the wave executor in
   `plan_and_execute`) and migrate the other two onto it. §4 Q4.
2. **Capability map collisions + docstring fiction.** `_cap_index` must
   become a list mapping, with a routing policy and a registration-time
   collision check. The `delegate_to_openclaw_agent` docstring must be
   generated from the live registry. §3 + §5.2 + §5.7.
3. **Errors must be exceptions, not strings.** `registry.query`,
   `plan_and_execute`, `checkpoint.load`, validators — all need to use
   the typed hierarchy in `exceptions.py` instead of returning prose
   that loses type information. §2.2.3, §6.3.
4. **Concurrent-run safety.** Either lock the project's checkpoint dir
   or fail fast if two runs share it. §4 Q1.
5. **Telemetry surface.** Turn on `logfire.instrument_pydantic_ai()`,
   stop leaking source bodies via `instrument_httpx`, attach
   `run_id`/`project` to every span. §1 high findings.

### 7.4 What is overbuilt and should be deleted or proven

- **The travel/finance agents** (`weather`, `accountant`, `holiday_planner`,
  `region_analyzer`, `current_events`, `asymmetric_reviewer`,
  `crypto_oracle`, `market_shark`, `price_analyst`) ship inside the same
  MCP server and the same registry as the SDLC pipeline. They share
  capability collisions, share `tool_assignments`, and confuse the
  caller-facing menu (§5.1). They have no test coverage in
  `tests/integration/`. Either split them into a separate MCP server or
  delete them — the current "everything in one repo" choice is
  costing clarity for negligible benefit.
- **Unused exception classes** (§6.3). Use or delete.
- **Hardcoded `OrgContext` defaults** in
  [main.py:102](main.py:102). Either pull from settings or remove the
  field — pretending it's parameterised when it isn't is worse than
  honestly hardcoding it.
- **`vector_db_stub.py`**. Either a meaningful test double or noise.
  Confirm during code review.

### 7.5 Verdict

**Ship the §3 quick wins. Then in order:**

1. Apply §4 Q1+Q2+Q3 (lock, per-run dirs, list capability map).
2. Apply §5.2 + §5.6 + §5.7 (truthful docstrings, structured outputs,
   namespaced capabilities).
3. Apply §6.3 + §6.4 (wire the exception hierarchy, enumerate tool
   categories).
4. Decide on travel/finance — split or delete.
5. Defer §4 Q4 (DAG migration) until the above are stable.

The result is the same conceptual architecture, finished. Not a rewrite.

---

## 8. Runtime Integration Status

Goal: openclaw's MCP server is reachable from each of the four runtimes
the user expects to drive it.

### 8.1 Discovery matrix

| Runtime | Config location | Launcher | Verified |
|---|---|---|---|
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` → `mcpServers.openclaw-agents` | `bash /Users/jocham/programming/agents/mcp_run.sh` | Config present; not smoke-tested in this session |
| Claude Code | `~/.claude.json` → `mcpServers.openclaw-agents` (also as plugin) | `bash /Users/jocham/programming/agents/mcp_run.sh` | ✅ `mcp__openclaw-agents__*` tools visible in this session |
| Hermes | `~/.hermes/config.yaml` → `mcp_servers.openclaw` | `/Users/jocham/programming/agents/.venv_313/bin/python src/openclaw/mcp_server.py` | ✅ `hermes mcp test openclaw` — connected in 18.5s, 13 tools |
| opencode | `~/.config/opencode/opencode.json` → `mcp.openclaw-agents` (global) | `bash /Users/jocham/programming/agents/mcp_run.sh` | Config present; project-local `opencode.json` has no MCP block (see 8.3) |

Direct stdio handshake also verified at the shell:

```text
$ echo '<MCP initialize JSON>' | bash mcp_run.sh
Starting MCP server (stdio mode)...
{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05",
 "capabilities":{"experimental":{},"prompts":{...},"resources":{...},
 "tools":{"listChanged":false}},
 "serverInfo":{"name":"OpenClaw","version":"1.27.1"}}}
```

13 tools are advertised. All four runtimes therefore have a working path.

### 8.2 Integration finding — virtualenv divergence — 🟡 Moderate

Hermes runs the server with `.venv_313/bin/python` (Python 3.13). The
other three runtimes go through `mcp_run.sh` which uses `.venv/bin/python`
(currently Python 3.14, per `.venv/bin/python -> python3.14`).

Two venvs means:

- A `pip install -e .[dev]` only updates one of them.
- A dependency-resolution change applies to `.venv` (via Makefile) but
  not `.venv_313`. The next Hermes call sees stale package versions.
- `pyproject.toml` declares `requires-python = ">=3.11"` and CI tests
  3.11 + 3.12; neither covers what either local venv runs.

**Recommendation:** standardise on one launcher. Point Hermes at
`mcp_run.sh` too (the file already activates `.venv` and exports
`PYTHONPATH`). Delete `.venv_313` if nothing else needs it. Add 3.13 or
3.14 to the CI matrix so the local Python version is at least exercised.

### 8.3 Integration finding — project-local opencode.json does not wire MCP — 🟡 Moderate

`/Users/jocham/programming/agents/opencode.json` defines 14 subagents
(business-analyst, backend-engineer, etc.) but has **no `mcp` block**.
Today opencode reaches openclaw only via the *global* config at
`~/.config/opencode/opencode.json`. A teammate cloning the repo and
running `opencode` inside it will:

1. Find the project-local `opencode.json` (subagents but no MCP).
2. Need to know to add the MCP entry to *their* global config.
3. Get confused that "the subagents work but openclaw tools don't".

**Recommendation:** add the MCP block to the project-local
`opencode.json`. One block, same shape as the Claude config:

```jsonc
"mcp": {
  "openclaw-agents": {
    "type": "local",
    "enabled": true,
    "command": ["./mcp_run.sh"]
  }
}
```

Using a relative path makes the wiring travel with the repo.

### 8.4 Integration finding — CI smoke test only checks import — 🟢 Minor

`.github/workflows/ci.yml` `mcp-test` job runs:

```bash
python -c "from openclaw.mcp_server import mcp; print('MCP server imports OK')"
```

That catches missing imports but not a broken `initialize` handshake. A
regression that breaks tool registration or changes the MCP protocol
version would slip through. The shell handshake test in 8.1 is one line
of bash; CI should run it.

**Recommendation:** extend the `mcp-test` job to actually start the
server via `mcp_run.sh`, send an `initialize` JSON message on stdin, and
assert the response has `result.serverInfo.name == "OpenClaw"` and
`len(result.capabilities.tools) >= 1`. A 5-line script.

---

## 9. Code Review — Fixes Applied This Pass

`engineering:code-review` skill applied to the diff. Scope: 16 changed files
(observability.py new; registry, registration, checkpoint, review,
service_engineer, mcp_server, a2a_tools, main.py edited; 4 test files
edited or added; ci.yml + opencode.json + scripts/mcp_handshake_check.py).

### Critical

_None._

### High

| # | File:line | Finding |
|---|---|---|
| H1 | [registration.py:11-12](src/openclaw/agents/registration.py:11) | `_REGISTRATION_SENTINEL = "ba"` is brittle. If `"ba"` is renamed or removed, the idempotency guard silently degrades and the second registration regresses to the original duplicate-registration crash. Use a module-level `_registered: bool = False` flag set at the top of `register_all_agents()`. |
| H2 | [service_engineer.py:17-24](src/openclaw/agents/service_engineer.py:17) + [existing_code_handler.py setter](src/openclaw/existing_code_handler.py) | `OPENCLAW_CODEBASE_ROOT` is a process-wide env var. Two concurrent `run_existing_code_pipeline` calls (legal via the MCP server) race on it — pipeline A can be re-sandboxed to pipeline B's root mid-flight. Should be a `contextvars.ContextVar`, with the env var as a test-time fallback. |
| H3 | [registration.py:11](src/openclaw/agents/registration.py:11), [mcp_server.py `_list_capabilities`](src/openclaw/mcp_server.py) | Both reach into `registry._agents` / `registry._cap_index` (private). Add a public `registry.is_registered(name) -> bool` and `registry.capabilities() -> Iterator[tuple[str, list[str]]]` so external callers stop poking at internals. |

### Medium

| # | File:line | Finding |
|---|---|---|
| M1 | [observability.py:64](src/openclaw/observability.py:64) | `contextlib.suppress(AttributeError)` covers the case where Logfire lacks `instrument_pydantic_ai`, but if pydantic-ai is *not installed*, calling the helper raises `ModuleNotFoundError` (not `AttributeError`). Extend the suppress tuple. |
| M2 | [review.py](src/openclaw/agents/review.py) | `REVIEW_BLUEPRINT_SUMMARY` / `REVIEW_BOUNDED_CONTEXTS` / `REVIEW_STRICT_MODE` are hardcoded module-level constants. Same finding as §6.5 — these belong in `settings.py` so operators can override without editing source. |
| M3 | [scripts/mcp_handshake_check.py](scripts/mcp_handshake_check.py) (caught + fixed before merge) | Initially spawned `bash mcp_run.sh`, which `source`s `.venv/bin/activate`. CI has no `.venv`; `set -e` would have aborted before the handshake. Fixed to use `sys.executable` directly. Lesson: anything that runs in CI must be tested in the CI's environment shape. |
| M4 | [registry.py:120-122](src/openclaw/registry.py:120) (`instrumented_query`) | Reads `registry._cap_index.get(...)` then `owners[0]`. If the list is ever transiently empty (mid-unregister), this `IndexError`s. Use `registry.owners_of(...)` and guard for empty. |
| M5 | [mcp_server.py `_list_capabilities`](src/openclaw/mcp_server.py) | Calls `register_all_agents()` on every invocation. Idempotent now (cheap), but still pulls in 27 module imports. Cache result, refresh on registry mutation. Low priority. |

### Low / nits

| # | File:line | Finding |
|---|---|---|
| L1 | [registry.py:96](src/openclaw/registry.py:96) | `query()` docstring says "Raises ... if the agent run fails"; it also raises `AgentNotFoundError` for missing capability. Mention both in the docstring. |
| L2 | [checkpoint.py:30-35](src/openclaw/checkpoint.py:30) | Atomic save is good; `os.fsync` blocks. Fine for the current write rate; worth a note for the per-substage checkpoint plan in §4 Q2. |
| L3 | [test_observability.py:51-67](tests/unit/test_observability.py:51) | `MagicMock()` accepts every attribute access, so the "instrument_pydantic_ai is called" assertion passes even after a future refactor that drops the call. Use `spec=logfire` to constrain to the real surface. |
| L4 | [registration.py:11](src/openclaw/agents/registration.py:11) comment | Claims "absence reliably means no registration has happened" — but partial registration (crash mid-loop) leaves `"ba"` registered and later agents not. The flag approach in H1 handles this naturally. |

### Contract changes to call out in the PR description

- `registry.query(...)` **raises** `AgentNotFoundError` / `AgentExecutionError` instead of returning prose strings. Callers that did substring matching (`"error" in result`) need updating. Already updated: `delegate_to_openclaw_agent`, `a2a_tools.delegate_to_agent`. `plan_and_execute` still works because its `except Exception` arm stores `f"ERROR: {e}"`.
- `registry._cap_index` is now `dict[str, list[str]]` not `dict[str, str]`. External code poking at this private attribute will break.
- `ReviewDependencies` was removed from `openclaw.agents.review`. No internal callers used it; an external caller (none found) would break.
- `OPENCLAW_CODEBASE_ROOT` is a new env var with security semantics — see H2.
- New MCP tool `list_openclaw_capabilities`. 13 → 14 tools.
- `delegate_to_openclaw_agent` docstring no longer enumerates capability names — it points callers at the new tool.

### What looks good

- Typed exceptions are finally used; the §6.3 "dead exception hierarchy" concern is resolved.
- Atomic checkpoint + sandboxed file ops both remove real failure modes with minimal surface churn.
- 18 new tests for the new contracts (capability lists, raised exceptions, atomic save, sandboxed read_file, idempotent registration, observability init). Test-to-source ratio ~1.5:1 on this change.
- The diff is purely additive in functionality — no signature change broke the existing suite (139/139 pass; lint + format + mypy clean).
- `scripts/mcp_handshake_check.py` is a real smoke test, not "does it import?" — it exercises the full stdio handshake. This is the kind of test that would have caught the registration crash from 2.2.5 if it had existed before.

### Verdict

**Approve with H1–H3 + M1 to be addressed before merging to main.**
H1 is a 3-line cleanup, M1 a 1-line extension. H2 is the contextvar swap
(~20 lines) and is the only remaining latent foot-gun in the new code.
H3 is a 5-line accessor addition that lets §5/§6 follow-up work land without
re-touching private attributes.


