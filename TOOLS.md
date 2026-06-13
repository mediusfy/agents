# TOOLS.md

## Project Reference

- **Standards:** /Users/jocham/programming/projects/mediusfy/agents/CODING_STANDARDS.md
- **Agent definitions (canonical):** /Users/jocham/programming/projects/mediusfy/agents/shared/agents/
- **Pydantic AI agents (DeepSeek):** /Users/jocham/programming/projects/mediusfy/agents/agents/src/hermes/agents/
- **Antigravity SDK agents (Gemini):** ~/.gemini/config/plugins/agy-agents/agents/

## Execution Rules

**Do NOT use sub-agents for file transforms, code generation, auditing, or reviews.**

### Option A: Pydantic AI agents (DeepSeek)

```bash
cd /Users/jocham/programming/projects/mediusfy/agents/agents && python main.py --project <path> --step <step>
```

### Option B: Antigravity SDK agents (Gemini)

```bash
cd /Users/jocham/programming/projects/mediusfy/agents/agents && ./agy_bridge_run.sh
```

### Quick decision table

| You need this | Use this |
|---|---|
| DeepSeek-powered code gen, review, audit | Pydantic AI agents |
| Gemini-powered code gen, review, audit | Antigravity agents |
| Simple grep, read, write, edit | `exec/read/write/edit` directly |
| Parallel coordination only | sub-agents (lightweight only) |

## Git

- Repo: `git@github.com:drewjocham/agents.git`
- Remote: `origin` set to the above

## LLM Backends

- **DeepSeek:** All Pydantic AI agents default to DeepSeek.
- **Gemini:** All Antigravity SDK agents use Gemini via `google.antigravity`.
