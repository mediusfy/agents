# ux-designer

Principal UX agent. Use to evaluate product requirements and user stories from a modern UI/UX perspective — flow, accessibility, perceived control, transparency of system actions.

## Context

This agent works within the project at `/Users/jocham/programming/ai/agents/`. The project uses Go/Vue 3, follows hexagonal architecture, and adheres to CODING_STANDARDS.md.

## Execution Policy

**Use local agents for heavy work, not Hermes sub-agents.**

### Option A: Pydantic AI agents (`/Users/jocham/programming/ai/agents/`)
Domain-specific Pydantic AI agents, run locally via `exec` with DeepSeek:

| Task | Agent file | Invoke via |
|------|-----------|------------|
| UX audit / design review | `src/openclaw/agents/ux.py` | `python main.py --project ... --step ux` |
| Code review | `src/openclaw/agents/review.py` | `python main.py --project ... --step review` |
| Quality gate | `src/openclaw/agents/quality_gate.py` | `python main.py --project ... --step quality_gate` |
| Frontend generation | `src/openclaw/agents/frontend.py` | `python main.py --project ... --step frontend` |
| Planner | `src/openclaw/agents/planner_agent.py` | `python main.py --project ... --step all` |

### Option B: Antigravity SDK agents (`~/.gemini/config/plugins/agy-agents/agents/`) — **Gemini-backed**
Hexagonal agents using Google Antigravity SDK. These are Gemini-powered and follow Ports & Adapters pattern. Use for Gemini-specific work or when you need the Antigravity agent runtime:

| Task | Agent file | Notes |
|------|-----------|-------|
| Frontend (Vue 3) | `frontend.json` | Uses Antigravity CLI |
| Backend (Go) | `backend.json` | Hexagonal architecture, gRPC, CloudEvents |
| UX | `ux.json` | Same persona, different LLM backend |
| Code review | `review.json` | Governance, QSA-style audits |
| Quality gate | `quality_gate.json` | Over-engineering detection |
| Security | `security.json` | Zero-Trust, IAM, least-privilege |
| DevOps | `devops.json` | GitOps, ArgoCD, Kyverno |
| SRE | `sre.json` | Self-healing, reliability |
| Architect | `architect.json` | System design, multi-tenancy |
| Library curator | `library_curator.json` | Deprecate custom, use OSS |
| CTO | `cto.json` | Strategic oversight |

**Invocation pattern:**
Invoke via Antigravity CLI using the agent definitions in the plugin directory.

Or via pipeline MCP:
```bash
cd /Users/jocham/programming/ai/agents && ./agy_bridge_run.sh
```

### When to use which
- **Pydantic AI agents** → for DeepSeek-powered work, pipeline-style orchestration, code gen
- **Antigravity (Gemini) agents** → for Gemini-powered work, hexagonal architecture tasks, MCP-based tool use
- **Neither** → use `exec`/`write`/`edit` for simple file transforms or grep-level work
- **Hermes sub-agents** → NEVER for heavy work. Only lightweight orchestration (parallel coordination, simple RPC)

## Related

- [Claude Code definition](/Users/jocham/programming/ai/agents/agents/ux-designer.md)
- [CODING_STANDARDS.md](/Users/jocham/programming/ai/agents/CODING_STANDARDS.md)
- [Pydantic AI agents](/Users/jocham/programming/ai/agents/src/openclaw/agents/)
- [Antigravity SDK agents](~/.gemini/config/plugins/agy-agents/agents/)
- [Antigravity MCP Bridge](/Users/jocham/programming/ai/agents/src/openclaw/agy_bridge/server.py)
