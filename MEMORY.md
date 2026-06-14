# MEMORY.md — Long-Term Memory

## How This Works

This file is the distilled, curated memory of important events, decisions, lessons learned,
and context. It is updated periodically from daily logs (`memory/YYYY-MM-DD.md`).
Outdated info is pruned. Think of it as long-term memory vs. the raw daily notes.

---

## Infrastructure & Deployment

- **Tails Docker orchestrator** lives in `programming/iac/home_tailscale/tails-for-docker`.
  It runs Tails-like containers with Tor, SimpleX Chat, and Tailscale SSH.
- Deployed on **Oracle Cloud Infrastructure (OCI)** using the Always-Free
  `VM.Standard.A1.Flex` (ARM64) shape.
- Terraform module at `terraform/modules/oci/tails_orchestrator`. Port 8080 open for REST API.
- AWS deployment module was removed in favor of OCI.
- The orchestrator uses **token-based authentication** (Bearer / X-Auth-Token headers)
  with auto-generated tokens at startup if `API_AUTH_TOKEN` is not set.

## Security Notes

- **Tailscale SSH only** — password auth disabled. MagicDNS bypass removed for amnesia user.
- All protocols blocked via iptables catch-all reject for the amnesia user.
- Docker stop on delete was fixed to resolve orphaned container cleanup.
- Generated API tokens are logged and flagged with `IsGenerated` config field.

## Architecture

- Go services follow **hexagonal architecture** (ports & adapters).
- Two main services: `region-resolver` and `entity-management`.
- Outbox pattern with idempotency for event publishing.
- CloudEvents envelopes for all events. NATS as event bus.
- Cursor-based pagination in PostgreSQL repositories.
- Shared library: `shared/go/residency/` for data residency zone mapping.

## AI Agent Ecosystem

- 14 specialized agents defined in `shared/agents/` (canonical source).
- Agent runtimes: Pydantic AI (DeepSeek), Antigravity SDK (Gemini), openclaw, Hermes.
- **Local agents preferred over Hermes sub-agents for heavy work.**
- CODING_STANDARDS.md is the single source of truth for all Go code.
- LiteLLM proxy at `localhost:4000` routes to multiple model providers.
- Logfire used for observability (traces, metrics).

## Key Decisions

- OCI over AWS for Always-Free ARM64 compute.
- Go 1.26 toolchain adopted early.
- Tailscale for secure networking between services.
- `shared/` directory as canonical location for shared code, agents, and workspace config.

## Conventions

- Go: gofmt, tabs, 100-120 char lines, three-group imports (stdlib / third-party / local).
- Error sentinels: `Err` prefix + PascalCase.
- Log keys: `logKey` prefix + PascalCase.
- Trace keys: `trace` prefix + snake_case.
- Interfaces: behavior + `er` suffix.
- Use `any` not `interface{}`.
