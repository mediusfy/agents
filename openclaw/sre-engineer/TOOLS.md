# TOOLS.md — SRE Engineer Local Setup

## Workspace

- **Configured workspace:** `/Users/jocham/Documents/obsidian/ai/` → symlink to `programming/ai/openclaw/sre-engineer/`
- **Actual home:** `/Users/jocham/programming/ai/openclaw/sre-engineer/`
- **Monorepo root:** `/Users/jocham/programming/ai/`
- **Agent SDK projects:** `/Users/jocham/programming/ai/agents/`

## Infrastructure

- **Hermes platform** — GKE + K3s, Terraform/Helm/ArgoCD
- **Agent orchestration** — pydantic_ai (DeepSeek), Antigravity (Gemini)
- **MCP server** — at `agents/src/openclaw/mcp_server.py`

## Key Paths

- Shared agent roles: `~root/shared/agents/*.md`
- Shared workspace templates: `~root/shared/workspace/*.md`
- Go coding standards: `~root/shared/standards/go-standards.md`
- Provider config docs: `~root/shared/docs/provider-config.md`
