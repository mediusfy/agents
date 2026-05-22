# openclaw

A multi-agent SDLC ecosystem with three layers:

1. **Claude Code plugin** (`agents/*.md`, `.claude-plugin/`) — 13 SDLC agents + Travel/Finance domain assistants
2. **opencode agents** (`.opencode/agents/`) — primary/subagent definitions with self-check and cross-review
3. **pydantic_ai Python agents** (`src/openclaw/agents/`) — runtime agents with structured outputs, tools, and MCP exposure

All AI traffic flows through Logfire for metrics, tracing, and token accounting at https://logfire-eu.pydantic.dev/drew/argus.

## Agents

### SDLC Agents (Claude Code + openclaw pipeline)
| Agent | When to use |
| --- | --- |
| `business-analyst` | Convert raw requirements to user stories, bounded contexts, event triggers |
| `cto` | Pre-implementation architecture review, ADR discipline, hard constraints |
| `ux-designer` | UX/accessibility review before frontend work begins |
| `backend-engineer` | Go 1.25+ hexagonal services, gRPC, NATS/Kafka, OpenTelemetry |
| `frontend-engineer` | Vue 3 + Composition API + TSX, WCAG 2.1 AA, real-time event bus UI |
| `database-engineer` | PostgreSQL migrations, indexing, Redis caching |
| `devops-engineer` | CI/CD (GitHub Actions / GitLab CI), Docker Compose, Makefiles |
| `sre-engineer` | Terraform/OpenTofu + Crossplane, GitOps, multi-region K8s |
| `security-engineer` | OWASP Top 10 audit, secrets scanning, structured findings report |
| `test-engineer` | BDD Playwright tests from Gherkin, with backend side-effect validation |
| `quality-gate` | Over-engineering detector with complexity scoring |
| `code-reviewer` | Final governance: drift detection against prior ADRs, risk ranking |
| `docs-writer` | OpenAPI specs, READMEs, runbooks |
| `planner-agent` | Break high-level goals into detailed step-by-step plans |

### Existing Code Agents (opencode primary + Claude Code rules)
| Agent / Rule | When to use |
| --- | --- |
| `service-coder` (opencode primary) | Modify EXISTING Go services — self-checks, delegates to library-curator, test-generator, code-inspector, functional-tester, architect |
| `code-inspector` (opencode subagent) | Cross-check: over-engineering, DRY, library misuse, CODING_STANDARDS compliance, pattern drift |
| `existing-code-workflow` (Claude rule) | Rule activated when modifying existing Go handlers, wiring, or refactoring |
| `code-inspection` (Claude rule) | Rule activated on "review this code" / "audit" / "quality check" |

### pydantic_ai Runtime Agents (MCP-accessible)
| Agent | Capability | Description |
| --- | --- | --- |
| `ba` | `requirements_analysis` | Business analysis, user stories, bounded contexts, event triggers |
| `backend` | `backend_dev` | Go hexagonal services, gRPC, NATS/Kafka, OpenTelemetry |
| `frontend` | `frontend_dev` | Vue 3 + Composition API + TSX, WCAG 2.1 AA, real-time event bus UI |
| `database` | `db_schema` | PostgreSQL migrations, indexing, Redis caching |
| `devops` | `ci_cd` | CI/CD (GitHub Actions / GitLab CI), Docker Compose, Makefiles |
| `sre` | `infrastructure` | Terraform/OpenTofu + Crossplane, GitOps, multi-region K8s |
| `security` | `security_audit` | OWASP Top 10 audit, secrets scanning, structured findings |
| `test_eng` | `go_test`, `playwright_test` | Table-driven Go tests + BDD Playwright |
| `quality_gate` | `quality_gate` | Complexity scoring, over-engineering detection |
| `review` | `code_review` | Final governance: security, architecture fit, standards compliance |
| `service_engineer` | `existing_code` | Modifies existing Go code with read_file/list_directory/gofmt tools |
| `planner_agent` | `task_planning` | Break high-level goals into executable task plans |
| `cto` | `arch_review` | Pre-implementation architecture pressure-test |
| `ux` | `ux_review` | UX/accessibility review before frontend work |
| `docs` | `docs_generation` | OpenAPI specs, READMEs, runbooks |
| `accountant` | `finance` | Budget management, expense calculation |
| `weather` | `weather` | Weather forecasts and climate summaries |
| `region_analyzer` | `region_analysis` | Geographical region safety/cost analysis |
| `asymmetric_reviewer` | `legal_review` | Legal/corporate travel savings analysis |
| `current_events` | `current_events` | News/historical context |

### Travel & Finance Agents
| Agent | When to use |
| --- | --- |
| `holiday-planner` | Coordinate travel plans, organize itineraries, and ensure a seamless travel experience |
| `region-analyzer` | Analyze geographical regions for safety, cost of living, and local attractions |
| `asymmetric-reviewer` | Law and corporate expert finding loopholes and asymmetric information to save money when traveling |
| `current-events` | Provide context on current events, blending modern news with historical perspectives |
| `weather` | Accurate weather forecasts, climate summaries, and travel-related weather advice |
| `accountant` | Manage budgets, calculate expenses, and provide financial advice for travel and general purposes |

## Pipelines

### Scaffold a new service
```
main.py --project my-service --requirement "Build a payment processing service"
```
Runs: BA → CTO/UX advisory → Backend + Frontend + Database → Test → Security → Quality Gate → Review

### Modify existing code
```
modify_existing_code(
    change_description="Add tracing to ProcessMessage handler in internal/service/message.go",
    codebase_path="/path/to/service"
)
```
Available as an MCP tool via `openclaw-agents` MCP server, or select the `service-coder` agent in opencode.

Runs: service_engineer → test_eng → quality_gate → review (each validates the previous step)

## Install

### Claude Code plugin
Add to `~/.claude/settings.json`:
```json
{
  "plugins": {
    "openclaw": {
      "source": "/Users/jocham/programming/agents"
    }
  }
}
```

### opencode agents
Project-local agents in `.opencode/agents/` are auto-discovered. Global agents in `~/.config/opencode/agents/` are also supported.

### MCP server
The `openclaw-agents` MCP server is configured in `~/.config/opencode/opencode.json` and `~/.claude/settings.json`. It exposes `modify_existing_code`, `delegate_to_openclaw_agent`, `run_openclaw_pipeline`, etc.

For Claude, the tool configuration in `settings.json` should be:
```json
{
  "tools": {
    "openclaw-agents": {
      "command": "bash",
      "args": [
        "/Users/jocham/programming/agents/mcp_run.sh"
      ]
    }
  }
}
```

For opencode, the configuration in `opencode.json` should be:
```json
{
  "mcpServers": {
    "openclaw-agents": {
      "command": "bash",
      "args": [
        "/Users/jocham/programming/agents/mcp_run.sh"
      ]
    }
  }
}
```
Make sure the path to `mcp_run.sh` is correct for your system.

### Environment
```bash
# Required for LLM calls
OPENAI_API_KEY="sk-..."
ANTHROPIC_API_KEY="sk-ant-..."
GEMINI_API_KEY="..."

# Required for metrics and tracing
LOGFIRE_TOKEN="pylf_v2_eu_..."

# Optional overrides
LOGFIRE_SEND_TO_LOGFIRE=true    # default: true when LOGFIRE_TOKEN is set
```

## Layout

```
.claude-plugin/
  plugin.json                # plugin manifest
.claude/rules/
  existing-code-workflow.md  # Claude Code rules for existing code
  code-inspection.md
.opencode/agents/
  service-coder.md           # opencode primary agent for existing code
  code-inspector.md          # opencode subagent for cross-check
agents/
  business-analyst.md        # 14 SDLC subagent definitions (Claude Code)
  backend-engineer.md
  ...
src/openclaw/                # Python pydantic-ai implementation
  agents/
    ba.py                    # Business analyst agent
    backend.py               # Go backend service engineer
    frontend.py              # Vue 3 frontend engineer
    test_eng.py              # Go table-driven test agent + Playwright agent
    service_engineer.py      # pydantic_ai agent for existing Go code
    registration.py          # Centralized agent registration
    ...                      # All SDLC + travel/finance agents
  existing_code_handler.py   # Pipeline orchestrator
  mcp_server.py              # MCP tool: modify_existing_code
main.py                      # CLI pipeline entry point
```

## Logfire Observability

All pydantic_ai agent runs are auto-instrumented. Every `agent.run()` call produces spans with:
- Token counts (prompt + completion)
- Latency per call
- Model name
- Structured input/output
- Error tracking

View at https://logfire-eu.pydantic.dev/drew/argus

## Troubleshooting

### Clear Cache
```bash
./scripts/clear_cache.sh
```