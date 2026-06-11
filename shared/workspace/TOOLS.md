# TOOLS.md

## Project Reference

- **Standards:** /Users/jocham/programming/ai/agents/CODING_STANDARDS.md
- **Agent definitions (Claude Code):** /Users/jocham/programming/ai/agents/agents/
- **Pydantic AI agents (USE THESE — DeepSeek):** /Users/jocham/programming/ai/agents/src/hermes/agents/
- **Antigravity SDK agents (USE THESE — Gemini):** ~/.gemini/config/plugins/agy-agents/agents/
- **Repo root:** /Users/jocham/programming/ai/agents/

## Execution Rules

**Do NOT use `sessions_spawn` for file transforms, code generation, auditing, or reviews.**

### Option A: Pydantic AI agents (DeepSeek)

```python
# Example: run UX audit via local Pydantic AI agent
cd /Users/jocham/programming/ai/agents && python -c "
import asyncio
from hermes.agents.registration import register_all_agents
from hermes.agents.ux import ux_agent

register_all_agents()
result = asyncio.run(ux_agent.run(input_text))
print(result.data)
"
```

Or use the pipeline CLI:
```
python main.py --project <path> --step ux
```

### Option B: Antigravity SDK agents (Gemini)

Run the bridge for MCP integration:
```bash
cd /Users/jocham/programming/ai/agents && ./agy_bridge_run.sh
```

### Quick decision
| You need this | Use this |
|---|---|
| DeepSeek-powered code gen, review, audit | Pydantic AI agents (`agents/src/hermes/agents/`) |
| Gemini-powered code gen, review, audit | Antigravity agents (`~/.gemini/config/plugins/agy-agents/agents/`) |
| Simple grep, read, write, edit | `exec/read/write/edit` directly |
| Parallel coordination only | `sessions_spawn` (lightweight only) |

## Git

- Repo: `git@github.com:drewjocham/agents.git`
- Local: `/Users/jocham/programming/ai/agents/` (monorepo containing ux-designer)
- Remote: `origin` set to the above

## DeepSeek

All Pydantic AI agents default to DeepSeek via settings. Don't ask, just use.

## Gemini

All Antigravity SDK agents use Gemini via `google.antigravity`.
