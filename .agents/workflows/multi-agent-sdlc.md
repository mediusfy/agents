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

## Full Pipeline

```
Planning → System Design → Testing Plan → Architect → Implementation → Gates → functional-tester → Remediation → BUDDY ✅ All Ok
```

### Step 1: Planning 🗺️
- Scope, goals, constraints, risks, timeline
- High-level approach
- Reviewed and approved by Rufkis

### Step 2: System Design 🏗️
- Architecture approach, component breakdown, data flow
- API surface, database changes, integration points
- Concrete enough for implementation
- Reviewed and approved by Rufkis

### Step 3: Testing Plan (mandatory before any code) ✅
- Functional verification criteria
- Edge cases, error handling, integration boundaries
- Regression safety
- Approved before any agent writes code

### Step 4: Architect Review
- Is the design sound?
- Does the testing plan cover the right things?
- Pattern compliance, structural integrity

### Step 5: Implementation + Gates + functional-tester
- service_engineer / agent writes code
- test_eng writes tests (TypeScript only)
- Parallel Verification Gates:
  ├── quality-gate (lint, test, build)
  ├── code-reviewer (logic, architecture, security)
  ├── library-curator (dependency health)
  └── architect (structural integrity)
- functional-tester runs the feature and confirms it works per the plan

### Step 6: Remediation Loop (max 3 retries on gate/functional failure)

### Step 7: BUDDY: Final Approval → ✅ All Ok
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
0. ✅ Planning (scope, goals, constraints)
1. ✅ System Design (architecture, data flow, API surface)
2. ✅ Testing Plan (mandatory, approved before any code)
3. ✅ Architect Review (design soundness, pattern compliance)
4. ✅ quality_gate (lint, complexity, standards)
5. ✅ code_reviewer (logic, architecture, security)
6. ✅ library-curator (dependency health)
7. ✅ functional-tester (runs the feature, confirms it works per the plan)
8. ✅ Max 3 remediation retries
9. ✅ BUDDY final approval with full agent suite
