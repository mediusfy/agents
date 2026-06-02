# Migration 002: Autonomous Agent Governance with MCP Access Policies

## Overview

This migration implements the database schema for RUFKIS-06, providing:

- **Agent Management** - Full lifecycle tracking of autonomous agents
- **MCP Server Registry** - Discovery metadata, transport configuration, OAuth provider info
- **MCP Capability Catalog** - Tools, Resources, Prompts with JSON schemas
- **Agent-Server Bindings** - With granular scope allowances
- **Access Policies** - CEL-based condition evaluation, DENY-over-ALLOW semantics
- **RBAC** - Roles, permissions, assignments
- **OAuth 2.1 Integration** - Client registrations, token tracking, PKCE support
- **Consent Management** - Per-client_id per-user consent (confused deputy prevention)
- **Audit Logging** - Immutable access audit trail
- **API Key & Session Management** - Hashed credentials, session rotation

### Index Strategy

Primary indexes on:
- Foreign keys (tenant_id, agent_id, mcp_server_id)
- Lookup columns (status, slug, deleted_at)
- Timestamps (created_at, expires_at)

### Security Design

- All token/secret storage uses hashed values (bcrypt, SHA-256)
- Row-level security considerations documented
- Audit logs are append-only (no UPDATE/DELETE in application code)
- Soft-delete pattern for agents, servers, bindings
