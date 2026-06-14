# `orchestration.agy_bridge` — Antigravity / agy CLI integration

## What this is

`agy_bridge` is the second exposure surface for Orgitration's registered agents. It speaks the **`agentapi` JSON-over-stdio protocol** so the Antigravity CLI (`agy`) and other agentapi clients can discover, inspect, and invoke Orgitration agents the same way they invoke their own native subagents.

The bridge **wraps the existing `AgentRegistry` without modifying any agent code.** Adding or removing agents in `orchestration.agents.registration.register_all_agents` automatically propagates here — there is no duplicate registration step.

## When to use it (vs. the MCP server)

Orgitration's agents are reachable through two parallel surfaces:

| Surface | Entrypoint | Protocol | Use when |
|---|---|---|---|
| MCP server | `src/orchestration/mcp_server.py` | Model Context Protocol over stdio | Claude Desktop, Cursor, Windsurf, any MCP-aware client |
| Agy bridge | `src/orchestration/agy_bridge/server.py` (this module) | `agentapi` JSON-over-stdio | Antigravity (`agy`) CLI/IDE, custom agentapi clients |

Both share the same backing registry — there is no behavioral fork. Pick whichever protocol your client speaks. You can run them simultaneously (separate processes).

## Module layout

```
agy_bridge/
├── __init__.py          # package marker
├── README.md            # this file
├── server.py            # stdio loop, dispatches commands → _handle_command
├── bridge_agent.py      # BridgeAgent: wraps a registry entry for agentapi
├── agent_sync.py        # writes .agents/agent.json files for agy discovery
└── hooks.py             # @on_session_start / @pre_tool_call / @post_turn decorators
```

## How to run it

### After `pip install -e .`

A console script is registered:

```bash
# Ping (one-shot)
echo '{"command":"ping"}' | orchestration-agy

# List all agents (one-shot)
echo '{"command":"list-agents"}' | orchestration-agy

# Daemon mode (Antigravity launches this as a subprocess)
orchestration-agy
```

### Without installing

```bash
python -m orchestration.agy_bridge.server <<< '{"command":"ping"}'
```

### Wiring into Antigravity

1. Run `echo '{"command":"sync-definitions"}' | orchestration-agy` to populate `.agents/<agent>/agent.json` definitions where `agy` looks for them.
2. Add the Orgitration repo to your Antigravity workspace; `agy` discovers the JSON definitions and treats each Orgitration agent as a subagent.
3. Invoke from Antigravity the same way you would any native subagent — the bridge translates calls into `registry.query(...)` under the hood.

## Public surface

### Commands accepted by `server.py`

The stdio loop reads one JSON object per line. Each command is a dict with a `"command"` key plus command-specific fields. An optional `"id"` field is echoed back in the response for correlation.

| Command | Args | Response |
|---|---|---|
| `ping` | — | `{"response": "pong", "timestamp": "..."}` |
| `list-agents` | — | `{"response": {"count": N, "agents": [{"name", "description", "tools"}]}}` |
| `get-agent` | `agent_name: str` | `{"response": {"name", "description", "tools"}}` or `{"error": "..."}` |
| `sync-definitions` | — | `{"response": {"synced": N}}` — writes `.agents/agent.json` files |

`server.py` runs in two modes:
- **One-shot:** pass JSON as `argv[1]` or pipe a single line on stdin → emit one response → exit.
- **Daemon:** stdin stays open → read line, dispatch, write response, repeat until EOF.

### `BridgeAgent` (`bridge_agent.py`)

Wraps a registered pydantic_ai agent for invocation through the `agentapi` `Conversation` interface. Construct via `BridgeAgent.from_registry(name)`. Exposes `get_system_prompt()`, `get_tool_names()`, and conversation lifecycle methods.

### Hook decorators (`hooks.py`)

Register Python-side lifecycle callbacks that fire during a bridge session:

```python
from orchestration.agy_bridge.hooks import on_session_start, pre_tool_call, post_turn

@on_session_start("planning")
async def warm_cache(ctx): ...

@pre_tool_call("implementation")
async def validate_path(ctx, tool_name, tool_args): ...
```

Hooks fire in registration order; raising from a hook aborts the lifecycle step.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `Agent 'foo' not registered` | `register_all_agents()` didn't include `foo` | Add the registration call in `orchestration.agents.registration` |
| `invalid JSON: ...` | malformed command on stdin | Validate JSON before piping; one object per line |
| Stuck after `server_started` event | client never sent a command | Daemon mode waits indefinitely on stdin; send a command or close stdin |
| Tools missing from `list-agents` response | agent has no tools registered | Check the agent's `register_tools(...)` call |

## Open items

- The `--with-bridge` flag mentioned in earlier `__init__.py` docs is **not implemented**. Run the bridge as a separate process for now.
- No durable session state — each command is independent. Multi-turn conversation state lives in the agentapi `Conversation` object passed by the client, not in this process.
- The bridge does not currently propagate Antigravity's `run_id` into `current_run_context` — bridge-initiated runs trace under their own root span. This is fine but means cross-surface trace correlation requires explicit ID passing.
