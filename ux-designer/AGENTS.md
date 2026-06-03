# ux-designer

Principal UX agent. Use to evaluate product requirements and user stories from a modern UI/UX perspective — flow, accessibility, perceived control, transparency of system actions.

## Context

This agent works within the project at `/Users/jocham/programming/agents/`. The project uses Go/Vue 3, follows hexagonal architecture, and adheres to CODING_STANDARDS.md.

## Execution Policy

**Use local agents for heavy work, not OpenClaw sub-agents.**

### Option A: Pydantic AI agents (`/Users/jocham/programming/agents/`)
Domain-specific Pydantic AI agents, run locally via `exec` with DeepSeek:

| Task | Agent file | Invoke via |
|------|-----------|------------|
| UX audit / design review | `src/openclaw/agents/ux.py` | `python main.py --project ... --step ux` |
| Code review | `src/openclaw/agents/review.py` | `python main.py --project ... --step review` |
| Quality gate | `src/openclaw/agents/quality_gate.py` | `python main.py --project ... --step quality_gate` |
| Frontend generation | `src/openclaw/agents/frontend.py` | `python main.py --project ... --step frontend` |
| Planner | `src/openclaw/agents/planner_agent.py` | `python main.py --project ... --step all` |

### Option B: Antigravity SDK agents (`/Users/jocham/programming/agy-agents/`) — **Gemini-backed**
Hexagonal agents using Google Antigravity SDK. These are Gemini-powered and follow Ports & Adapters pattern. Use for Gemini-specific work or when you need the Antigravity agent runtime:

| Task | Agent file | Notes |
|------|-----------|-------|
| Frontend (Vue 3) | `agy_agents/frontend.py` | Uses `AntigravityAgentAdapter` → Gemini |
| Backend (Go) | `agy_agents/backend.py` | Hexagonal architecture, gRPC, CloudEvents |
| UX | `agy_agents/ux.py` | Same persona, different LLM backend |
| Code review | `agy_agents/review.py` | Governance, QSA-style audits |
| Quality gate | `agy_agents/quality_gate.py` | Over-engineering detection |
| Security | `agy_agents/security.py` | Zero-Trust, IAM, least-privilege |
| DevOps | `agy_agents/devops.py` | GitOps, ArgoCD, Kyverno |
| SRE | `agy_agents/sre.py` | Self-healing, reliability |
| Architect | `agy_agents/architect.py` | System design, multi-tenancy |
| Library curator | `agy_agents/library_curator.py` | Deprecate custom, use OSS |
| CTO | `agy_agents/cto.py` | Strategic oversight |

**Invocation pattern:**
```python
from agy_agents.adapters import AntigravityAgentAdapter
from agy_agents.ux import UxAgent

adapter = AntigravityAgentAdapter()
agent = UxAgent(provider=adapter)
response, cid = await agent.run("Analyze this UI...")
```

Or via CLI:
```
cd /Users/jocham/programming/agy-agents && python main.py
```

### When to use which
- **Pydantic AI agents** → for DeepSeek-powered work, pipeline-style orchestration, code gen
- **Antigravity (Gemini) agents** → for Gemini-powered work, hexagonal architecture tasks, MCP-based tool use
- **Neither** → use `exec`/`write`/`edit` for simple file transforms or grep-level work
- **OpenClaw sub-agents** → NEVER for heavy work. Only lightweight orchestration (parallel coordination, simple RPC)

## Related

- [Claude Code definition](/Users/jocham/programming/agents/agents/ux-designer.md)
- [CODING_STANDARDS.md](/Users/jocham/programming/agents/CODING_STANDARDS.md)
- [Pydantic AI agents](/Users/jocham/programming/agents/src/openclaw/agents/)
- [Antigravity SDK agents](/Users/jocham/programming/agy-agents/agy_agents/)
- [Antigravity SDK adapter](/Users/jocham/programming/agy-agents/agy_agents/adapters.py)
- [Agent provider port (abstract)](/Users/jocham/programming/agy-agents/agy_agents/ports.py)
