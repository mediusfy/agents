# Provider Configuration Reference

This repo (`programming/ai/agents/`) is the **central config hub** for all AI agent providers.
Provider-specific configuration files live here so they can be version-controlled, shared, and
symlinked into thin provider workspace directories under `programming/ai/<provider>/`.

---

## Provider References

| Provider | Config Files | How It Discovers This Repo |
|----------|-------------|---------------------------|
| **OpenCode** | `opencode.json`, `.opencode/agents/*.md`, `.opencode/package.json` | `cd programming/ai/opencode; opencode .` — symlinked workspace templates, discovers `opencode.json` at repo root as project config |
| **Claude Code** | `.claude/rules/*.md`, `.claude/settings.local.json` | Project-level `.claude/` is auto-detected by Claude Code when run from `programming/ai/claude/` |
| **Hermes** | `.claude-plugin/plugin.json`, `.agents/workflows/*.md` | Hermes discovers its own configs from repo root; workspaces at `docs-writer/` and `frontend-engineer/` inherit shared templates via symlinks |
| **Antigravity** | `.aivory/`, `.antigravitycli/` (symlink to Gemini config) | Antigravity-specific runtime configs |
| **Hermes** | `.hermes/plans/` (future) | Hermes discovers its own plans directory |

---

## How Providers Find Their Configs

### OpenCode

OpenCode reads `opencode.json` from the current working directory. When running from
`programming/ai/opencode/`, it discovers `opencode.json` at the repo root via relative path
resolution (or by setting the OpenCode `projectRoot` config).

The `.opencode/agents/*.md` subagent definitions are referenced from `opencode.json`
and loaded automatically by OpenCode.

### Claude Code

Claude Code auto-discovers `.claude/` and `.claude-plugin/` in the project root.
No additional configuration is needed — running `claude` from within the repo picks up everything.

**Required permissions:** Add MCP tool permissions to `.claude/settings.local.json`:
```json
{
  "permissions": {
    "allow": [
      "mcp__hermes-agents__*",
      "mcp__sonarqube__quality_gate_status"
    ]
  }
}
```

### Hermes (Workspace)

Hermes discovers its workspace configs from the agent workspace root. The shared templates
are symlinked from `programming/ai/shared/workspace/`. Provider-specific files like
`GUIDELINES.md` live at the provider level alongside the symlinks.

### Antigravity

Antigravity CLI reads `.antigravitycli/` from its working directory. The config is a symlink
to the Gemini project config at `~/.gemini/config/projects/<uuid>.json`.

---

## Adding a New Provider

1. Create `programming/ai/<provider>/` directory
2. Symlink the shared workspace templates:
   ```bash
   cd programming/ai/<provider>
   for f in ../shared/workspace/*.md; do ln -sf "$f"; done
   ln -sf ../shared/agents/*.md agents/
   ```
3. Add provider-specific config files to `programming/ai/agents/` (this repo)
4. Document the provider config location in this file

---

## Important: Shared vs Provider-Specific Files

| Shared (`shared/`) | Provider-Specific (in `agents/` repo) |
|-------------------|--------------------------------------|
| Agent role definitions (`shared/agents/*.md`) | `.claude/` — Claude Code project rules |
| Workspace templates (`shared/workspace/*.md`) | `.opencode/` — OpenCode agents + MCP config |
| Coding standards (`shared/standards/*.md`) | `.agents/` — Hermes agent workflows |
| Provider config docs (`shared/docs/provider-config.md`) | `.claude-plugin/` — Claude plugin manifest |
| | `opencode.json` — OpenCode project configuration |
| | `.pre-commit-config.yaml` — Git hooks |
