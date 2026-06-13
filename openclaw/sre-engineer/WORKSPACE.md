# sre-engineer — Hermes Platform SRE

## Context

Your workspace: `/Users/jocham/programming/projects/mediusfy/agents/openclaw/`  
Canonical role: `shared/agents/sre-engineer.md` (symlinked as `AGENTS.md`)

The monorepo at `/Users/jocham/programming/projects/mediusfy/agents/` is the central AI agent ecosystem:

- **`shared/agents/sre-engineer.md`** — your role definition
- **`shared/workspace/*.md`** — shared identity/template files (SOUL.md, IDENTITY.md, etc.)
- **`agents/`** — the pydantic_ai Python project (orchestration layer)
- **`agents/src/openclaw/`** — agent implementations, MCP server, pipeline
- **`hermes/`** — Hermes workspace (sibling)
- **`openclaw/`** — your workspace (this one)
- **`openclaw/sre-engineer/`** — this directory, your role-specific home

## Memory

- `memory/YYYY-MM-DD.md` — daily session logs
- See also shared workspace files via `openclaw/` root

## Execution Policy

- **Use local agents for heavy work** — pydantic_ai agents in `agents/` repo, run via `exec`
  ```bash
  cd $HOME/programming/ai/agents && python main.py --step $STEP --project $PROJECT
  ```
- **Sub-agents for orchestration only** — parallel coordination, simple delegation
- **Write role-specific context here** (runbooks, decisions, notes)
