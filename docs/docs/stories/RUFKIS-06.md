# RUFKIS-06: Autonomous Agent Governance with MCP Access Policies

## Domain Analysis

### Bounded Context: Governance
**Aggregate Root:** `Agent` (governed entity)

This bounded context spans the intersection of **Governance** (policies/audit) and **AgentOrchestration** (agent lifecycle & MCP connectivity).

### Domain Model

#### Entities

1. **Agent** - An autonomous software agent that connects via MCP
   - Status lifecycle: Draft → Active → Suspended → Deactivated
   - Multi-tenant: each agent belongs to a `tenant_id`
   
2. **McpServer** - A registered MCP server endpoint
   - Supports HTTP SSE, Streamable HTTP, and STDIO transports
   - Stores OAuth discovery metadata (resource metadata URL, authorization server info)
   
3. **McpToolDefinition / McpResourceDefinition / McpPromptDefinition** - Capabilities exposed by MCP servers
   - JSON schema for input validation
   - Linked to parent MCP server

4. **AgentMcpBinding** - Binds an agent to an MCP server with specific scope allowances
   - Many-to-many with approval status

5. **AccessPolicy** - A policy statement granting/denying access
   - Effect: ALLOW | DENY
   - Resource pattern (URI glob/prefix matching per MCP spec)
   - Conditions via CEL expressions

6. **Role / RoleAssignment** - RBAC support
   - Predefined roles: Admin, Operator, Developer, Auditor, Agent-Runtime

7. **OauthClientRegistration** - OAuth 2.1 client metadata per agent/server pair
   - Supports Client ID Metadata Documents and Dynamic Registration

8. **ConsentRecord** - User consent tracking for agent-server authorization
   - Prevents confused deputy attacks

9. **AccessAuditLog** - Immutable audit trail

10. **ApiKey / AgentSession** - Credential management

### Events

| Event | Producer | Consumers |
|-------|----------|-----------|
| AgentCreated | Governance | AgentOrchestration, AuditTrail |
| AgentStatusChanged | Governance | AgentOrchestration, Notifications |
| McpServerRegistered | Governance | AgentOrchestration |
| McpServerStatusChanged | Governance | AgentOrchestration, Diagnostics |
| AgentBoundToMcpServer | Governance | AgentOrchestration |
| AccessPolicyCreated | Governance | AgentOrchestration |
| AccessPolicyEvaluated | Governance | AuditTrail |
| OauthTokenIssued | Governance | None (stored ephemerally) |
| ConsentGranted | Governance | AgentOrchestration |
| ConsentRevoked | Governance | AgentOrchestration |
| AccessAuditLogged | Governance | AuditTrail |

### Business Rules

1. An Agent must have at least one binding to an active MCP server before it can operate
2. Every MCP tool invocation must be evaluated against ALL applicable AccessPolicies
3. DENY policies always override ALLOW policies
4. OAuth tokens must be audience-bound to the specific MCP server (per RFC 8707)
5. Consent records must be per-client_id per-user (prevents confused deputy)
6. AccessPolicies support progressive scope elevation via WWW-Authenticate challenges
7. API Keys must be hashed with bcrypt before storage
8. Session tokens must be short-lived (max 15 min) with refresh rotation
