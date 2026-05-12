# openclaw

A Claude Code plugin that adds a 13-agent SDLC team — from business analysis through architecture, implementation, testing, security, and final governance review.

The original Python implementation (pydantic-ai based) still lives under `src/openclaw/` and `main.py`. The Claude Code plugin lives under `.claude-plugin/` and `agents/`.

## Agents

| Agent | When to use |
| --- | --- |
| `business-analyst` | Convert raw requirements to user stories, bounded contexts, event triggers |
| `cto` | Pre-implementation architecture review, ADR discipline, hard constraints |
| `ux-designer` | UX/accessibility review before frontend work begins |
| `backend-engineer` | Go 1.26+ hexagonal services, gRPC, NATS/Kafka, OpenTelemetry |
| `frontend-engineer` | Vue 3 + Composition API + TSX, WCAG 2.1 AA, real-time event bus UI |
| `database-engineer` | PostgreSQL migrations, indexing, Redis caching |
| `devops-engineer` | CI/CD (GitHub Actions / GitLab CI), Docker Compose, Makefiles |
| `sre-engineer` | Terraform/OpenTofu + Crossplane, GitOps, multi-region K8s |
| `security-engineer` | OWASP Top 10 audit, secrets scanning, structured findings report |
| `test-engineer` | BDD Playwright tests from Gherkin, with backend side-effect validation |
| `quality-gate` | Over-engineering detector with complexity scoring |
| `code-reviewer` | Final governance: drift detection against prior ADRs, risk ranking |
| `docs-writer` | OpenAPI specs, READMEs, runbooks |

## Install

This plugin is a local directory plugin. Two ways to use it:

### Per-project (recommended for trying it out)

Add to the project's `.claude/settings.json`:

```json
{
  "plugins": {
    "openclaw": {
      "source": "/Users/jocham/programming/agents"
    }
  }
}
```

### Globally for all your projects

Add to `~/.claude/settings.json` under the same `plugins` key.

After installing, restart Claude Code and the subagents appear in `/agents`. Invoke one with e.g. `@backend-engineer scaffold a payments service` or let Claude auto-route based on the `description` field.

## Layout

```
.claude-plugin/
  plugin.json          # plugin manifest
agents/
  business-analyst.md  # 13 subagent definitions
  backend-engineer.md
  ...
src/openclaw/          # original Python pydantic-ai implementation (unchanged)
main.py
```

## Customizing

Each `agents/*.md` is a standalone subagent. Edit the system prompt freely; the YAML frontmatter (`name`, `description`, `tools`, `model`) controls how Claude Code discovers and routes to it. Restrict `tools` further if you want a stricter sandbox per agent.
