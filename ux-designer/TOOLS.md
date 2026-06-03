# TOOLS.md

## Project Reference

- **Standards:** /Users/jocham/programming/agents/CODING_STANDARDS.md
- **Agent definitions:** /Users/jocham/programming/agents/agents/
- **Pydantic AI agents (USE THESE):** /Users/jocham/programming/agents/src/openclaw/agents/
- **Repo root:** /Users/jocham/programming/agents/

## Execution Rules

**Do NOT use `sessions_spawn` for file transforms, code generation, auditing, or reviews.**

Use the local Pydantic AI agents via `exec` instead:

```
# Example: run UX audit via local agent
cd /Users/jocham/programming/agents && python -c "
import asyncio
from openclaw.agents.registration import register_all_agents
from openclaw.agents.ux import ux_agent

register_all_agents()
result = asyncio.run(ux_agent.run(input_text))
print(result.data)
"
```

Or use the pipeline CLI:
```
python main.py --project <path> --step ux
```

Sub-agents only for: parallel coordination, simple status checks, lightweight orchestration.

## Git

- Repo: `git@github.com:drewjocham/agents.git`
- Local: `/Users/jocham/programming/openclaw/` (monorepo containing ux-designer)
- Remote: `origin` set to the above

## DeepSeek

All Pydantic AI agents default to DeepSeek via settings. Don't ask, just use.
