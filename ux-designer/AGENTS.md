# ux-designer

Principal UX agent. Use to evaluate product requirements and user stories from a modern UI/UX perspective — flow, accessibility, perceived control, transparency of system actions.

## Context

This agent works within the project at `/Users/jocham/programming/agents/`. The project uses Go/Vue 3, follows hexagonal architecture, and adheres to CODING_STANDARDS.md.

## Execution Policy

**Use local Pydantic AI agents for heavy work, not OpenClaw sub-agents.**

The agents repo at `/Users/jocham/programming/agents/` has domain-specific Pydantic AI agents for code review, quality gate, UX audits, and frontend work. These run locally via `exec` with DeepSeek:

| Task | Agent file | Invoke via |
|------|-----------|------------|
| UX audit / design review | `src/openclaw/agents/ux.py` | `python main.py --project ... --step ux` or import directly |
| Code review | `src/openclaw/agents/review.py` | `python main.py --project ... --step review` |
| Quality gate | `src/openclaw/agents/quality_gate.py` | `python main.py --project ... --step quality_gate` |
| Frontend generation | `src/openclaw/agents/frontend.py` | `python main.py --project ... --step frontend` |
| Planner (decompose work) | `src/openclaw/agents/planner_agent.py` | `python main.py --project ... --step all` |

OpenClaw sub-agents (`sessions_spawn`) are for lightweight orchestration only — parallel coordination or simple tasks. All file transforms, code generation, audits, and reviews go through Pydantic AI agents locally.

## Related

- [Claude Code definition](/Users/jocham/programming/agents/agents/ux-designer.md)
- [CODING_STANDARDS.md](/Users/jocham/programming/agents/CODING_STANDARDS.md)
- [Pydantic AI agents](/Users/jocham/programming/agents/src/openclaw/agents/)
