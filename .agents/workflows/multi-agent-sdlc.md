---
name: multi-agent-sdlc-pipeline
description: The full SDLC pipeline orchestrated by BUDDY through the OpenClaw MCP server. Spans OpenClaw agents, opencode sub-agents, and Claude Code agents.
---

# Multi-Agent SDLC Pipeline

## Orchestration Flow
```
Rufkis → BUDDY (Lead Orchestrator)
         ├─ MCP Server → OpenClaw agents (pydantic_ai)
         ├─ OpenCode sub-agents (service-coder, test-generator, functional-tester, etc.)
         ├─ Claude Code agents (backend-go-engineer, sre-engineer, etc.)
         └─ Autonomous Remediation Loop (quality gates + retries)
```

## Mandatory: Testing Plan Before Any Code

**Every feature request, before any agent writes a single line of code, MUST include a testing plan.** This is not optional and is enforced in the pipeline.

### Pipeline — Per-Feature Execution
```
Rufkis → BUDDY
  │
  ├── Step 1: TESTING PLAN (mandatory before any code)
  │   ├── What functional behavior must be verified?
  │   ├── What edge cases exist?
  │   ├── How do we prove the feature actually works?
  │   ├── What tests validate the acceptance criteria?
  │   └── Approved by BUDDY before Step 2 begins
  │
  ├── Step 2: Architect review
  │   └── Is the approach sound based on the testing plan?
  │
  ├── Step 3: Implementation + functional-tester verification
  │   ├── service_engineer / agent writes code
  │   ├── test_eng writes tests (TypeScript only)
  │   └── functional-tester runs the feature and confirms it works
  │
  ├── Step 4: Parallel Verification Gates
  │   ├── quality-gate (lint, test, build)
  │   ├── code-reviewer (logic, architecture, security)
  │   ├── library-curator (dependency health)
  │   └── architect (structural integrity)
  │
  ├── Step 5: Remediation Loop (max 3 retries on gate failure)
  │
  └── BUDDY: Final Approval → ✅ All Ok
```

### Testing Plan Requirements

The testing plan must cover:

1. **Functional tests** — What does working look like? How do we prove the feature actually works?
2. **Edge cases** — What happens when inputs are empty, malformed, missing, or extreme?
3. **Error handling** — What happens when the feature fails? Are errors graceful?
4. **Integration boundaries** — Does this touch other features? Are those interactions tested?
5. **Regression safety** — What existing tests must continue to pass?

### Testing Plan Enforcement

Enforced at every level of the pipeline:

**At the Orchestrator Level (BUDDY):**
- When you hand me a feature request, I first produce a **Testing Plan** before dispatching to any agent
- No agent runs code until the testing plan is approved
- The testing plan is saved to the feature context and carried forward

**At the Agent Level:**
- Every agent receives the testing plan as part of their context
- `test_eng` writes tests against the testing plan acceptance criteria
- `functional-tester` executes the feature and validates against the testing plan
- `code-reviewer` checks that tests actually cover the declared plan

**At the Implementation Level:**
- `service_engineer` writes code **knowing** what the tests will verify
- `test_eng` writes TypeScript tests first, against the plan's acceptance criteria
- `functional-tester` is invoked at the end of each sprint:
  - Builds and runs the app (or the relevant component)
  - Executes the functional test scenarios from the testing plan
  - Reports PASS/FAIL per scenario
  - If anything fails → routes back to `service_engineer`

## Agent Inventory

### OpenClaw (Pydantic AI) — 25+ agents
Registered in `src/openclaw/agents/registration.py`

### OpenCode Sub-agents — 6 agents
At `.opencode/agents/`: architect, code-inspector, functional-tester, library-curator, service-coder, test-generator

### Claude Code Agents — 6 agents
At `~/.claude/agents/`: backend-go-engineer, board-of-review, business-analyst, frontend-ux-engineer, sre-engineer, test-engineer

## Spawn Patterns
- **OpenClaw agents:** via `delegate_to_openclaw_agent(capability, context, task)`
- **OpenCode sub-agents:** via `sessions_spawn(runtime="acp", agentId="opencode", ...)` or direct delegation from service-coder
- **Claude Code agents:** via `sessions_spawn(runtime="acp", agentId="claude", task="Call backend-go-engineer: ...")`
- **Inside Claude Code:** `/agents` opens subagent manager, `/background` detaches, `/batch` parallelizes, `/code-review --fix` reviews + fixes

## Quality Guarantees
Every pipeline run includes:
0. ✅ Testing Plan (mandatory, approved before any code)
1. ✅ quality_gate (lint, complexity, standards)
2. ✅ code_reviewer (logic, architecture, security)
3. ✅ library-curator (dependency health)
4. ✅ architect (structural integrity)
5. ✅ functional-tester (runs the feature, confirms it works per the plan)
6. ✅ Max 3 remediation retries
7. ✅ BUDDY final approval with full agent suite
