# openclaw

A multi-agent SDLC ecosystem with three layers:

1.  **Claude Code plugin** (`agents/*.md`, `.claude-plugin/`) — 13 SDLC agents + Travel/Finance domain assistants
2.  **opencode agents** (`.opencode/agents/`) — primary/subagent definitions with self-check and cross-review
3.  **pydantic_ai Python agents** (`src/openclaw/agents/`) — runtime agents with structured outputs, tools, and MCP exposure

All AI traffic flows through Logfire for metrics, tracing, and token accounting at [https://logfire-eu.pydantic.dev/drew/argus](https://logfire-eu.pydantic.dev/drew/argus).

## Directory Structure

```
agents/*.md                  # Claude Code agent definitions (detailed system prompts)
.opencode/agents/*.md        # OpenCode primary + subagent definitions
.claude-plugin/plugin.json   # Claude Code plugin manifest
.claude/rules/*.md           # Claude Code rules (auto-triggered on keywords)
src/openclaw/                # Python pydantic_ai runtime
  agents/                    # Agent implementations (pydantic_ai Agents)
  agents/non_technical/      # Finance/travel agents
  tools/                     # Shared tools (market data, A2A delegation)
  models/                    # Pydantic output models + model factory
  mcp_server.py              # MCP server exposing agents as tools
  registry.py                # Capability-based agent registry
  settings.py                # pydantic-settings configuration
  existing_code_handler.py   # Pipeline orchestrator for existing code mods
main.py                      # CLI pipeline entry point
start_mcp.py                 # MCP server launcher (production)
tests/                       # pytest test suite
CODING_STANDARDS.md          # Go coding standards (for generated code)
```

## Agents

### Core SDLC Pipeline Agents
| Agent | Description |
| --- | --- |
| `business-analyst` / `ba` | Converts raw requirements into bounded contexts, user stories, and event triggers. |
| `cto` | Pre-implementation architecture reviews, enforcing ADR discipline and hard constraints. |
| `ux-designer` / `ux` | Accessibility (WCAG 2.1 AA) and UX reviews prior to frontend implementation. |
| `backend-engineer` / `backend` | Go (1.25+) hexagonal architecture, gRPC, NATS/Kafka, and OpenTelemetry. |
| `frontend-engineer` / `frontend` | Vue 3, Composition API, TSX, and real-time event bus UI. |
| `database-engineer` / `database` | PostgreSQL migrations, indexing strategies, and Redis caching. |
| `devops-engineer` / `devops` | CI/CD pipelines, Docker Compose, and Makefiles. |
| `sre-engineer` / `sre` | Terraform/OpenTofu, Crossplane, GitOps, and multi-region K8s deployments. |
| `security-engineer` / `security` | OWASP Top 10 audits, secret scanning, and structured findings. |
| `test-engineer` / `test_eng` | Table-driven Go tests and BDD Playwright from Gherkin. |
| `quality-gate` | Complexity scoring and over-engineering detection. |
| `code-reviewer` / `review` | Final governance, drift detection against ADRs, and risk ranking. |
| `docs-writer` / `docs` | OpenAPI specs, runbooks, and README generation. |
| `planner-agent` | Breaks high-level goals into step-by-step execution plans. |

### Existing Code Modification Agents
| Agent | Description |
| --- | --- |
| `service-coder` (Opencode) | Modifies existing Go services. Triggers self-checks and delegates to specialized subagents. |
| `code-inspector` (Opencode) | Audits for DRY violations, over-engineering, and pattern drift. |
| `service_engineer` (MCP) | Modifies Go code using local read/write and `gofmt` tools. |

*(Note: Claude Code uses specific rules like `existing-code-workflow` and `code-inspection` to automatically trigger the right behaviors when refactoring or auditing code).*

### Domain Expert Agents (Travel & Finance)
| Agent | Description |
| --- | --- |
| `holiday-planner` | Itinerary organization and travel coordination. |
| `region-analyzer` | Cost of living, safety, and geographical analysis. |
| `asymmetric-reviewer` | Corporate/legal travel savings and loophole identification. |
| `current-events` | Modern news blended with historical context. |
| `weather` | Forecasts and climate summaries. |
| `accountant` | Budget management and expense calculation. |

## Installation & Setup

### Opencode Agents
Project-local agents in `.opencode/agents/` are auto-discovered. Global agents in `~/.config/opencode/agents/` are also supported.

Configure your `opencode.json` to register the MCP servers:
```json
{
  "mcpServers": {
    "agents": {
      "command": "bash",
      "args": ["/Users/jocham/programming/agents/mcp_run.sh", "--logfire-token", "YOUR_LOGFIRE_TOKEN"],
      "enabled": true
    },
    "redis-mcp-server": {
      "command": "uvx",
      "args": [
        "--from", "redis-mcp-server@latest",
        "redis-mcp-server",
        "--url", "redis://<YOUR_REDIS_URL>"
      ]
    }
  }
}
```

### Claude Code (MCP Server)
The `openclaw-agents` server exposes tools like `modify_existing_code` and `run_openclaw_pipeline`.

**Note:** Claude reads MCP configs from `~/.claude.json`, not the settings directory. Always use the CLI to add servers.

1.  **Register the server:**
    ```bash
    claude mcp add --scope user openclaw-agents -- /bin/bash /Users/jocham/programming/agents/mcp_run.sh
    ```

2.  **Verify the connection:**
    ```bash
    claude mcp get openclaw-agents
    ```
    You should see `Status: ✓ Connected`. If it fails, verify `mcp_run.sh` is executable and your `.venv` is properly configured. Crucially, `mcp_run.sh` must use `exec` on the final python command so stdin/stdout bypasses shell buffering.

3.  **To remove the server:**
    ```bash
    claude mcp remove openclaw-agents -s user
    ```

### Antigravity Configuration
If you are using Antigravity, add this to your config:
```json
"openclaw-agents": {
  "command": "/Users/jocham/programming/agents/mcp_run.sh",
  "args": []
}
```

### Environment Variables
```bash
# LLM Providers
OPENAI_API_KEY="sk-..."
ANTHROPIC_API_KEY="sk-ant-..."
GEMINI_API_KEY="..."

# Observability
LOGFIRE_TOKEN="pylf_v2_eu_..."
LOGFIRE_SEND_TO_LOGFIRE=true # defaults to true if token is present
```

## Observability & Maintenance

All `pydantic_ai` runs are auto-instrumented. Every `agent.run()` produces a span containing token usage, call latency, model name, input/output structures, and error traces.

To clear the local cache:
```bash
./scripts/clear_cache.sh
```