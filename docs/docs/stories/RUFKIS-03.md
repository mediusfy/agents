# RUFKIS-03: Agent Creation Wizard

## Story
**As a** platform user (developer or ops engineer)
**I want** to create a new AI agent through a guided multi-step wizard
**So that** I can quickly bootstrap an agent with a defined identity, knowledge sources, and tool bindings without manual YAML or API configuration.

## Status
- [ ] Architecture Decision Record (ADR) approved
- [x] Domain analysis complete
- [ ] API specification complete
- [ ] Implementation pending
- [ ] Integration tests pending

## Context
The Agent Creation Wizard provides a guided multi-step flow for creating AI agents on the Rufkis platform. Users progress through four defined steps (DEFINE_IDENTITY, CONFIGURE_KNOWLEDGE, ASSIGN_TOOLS, REVIEW) with server-side state persistence, async knowledge ingestion, and eventual consistency handoff to the AgentConfiguration context.

The wizard is the primary entry point for agent lifecycle management, enabling users to bootstrap agents with identity, capabilities, ingested knowledge sources, and tool bindings — all without writing YAML or interacting directly with APIs.

## Domain Model

### Bounded Context: AgentCreation (Core Domain)

**Aggregate Root:** `AgentDraft` — The in-progress agent creation session; encapsulates all partial state until finalization.

**Entities:**
| Entity | Description |
|--------|-------------|
| `AgentDraft` (AR) | Holds WizardSessionId, CurrentStep, DraftMetadata, namespace, userId |
| `WizardStep` | Tracks step type (DEFINE_IDENTITY, CONFIGURE_KNOWLEDGE, ASSIGN_TOOLS, REVIEW), completion status, data payload per step |
| `KnowledgeSourceItem` | Represents a single source being ingested (file, URL, raw text) with status tracking |
| `ToolBindingDraft` | Represents a tool-to-agent association in progress with configuration |
| `CapabilitySelection` | Captures chosen capabilities (CHAT, CODE_EXECUTION, WEB_SEARCH, FILE_PROCESSING, API_ORCHESTRATION) |

**Value Objects:**
| Value Object | Type | Description |
|-------------|------|-------------|
| `WizardSessionId` | UUID | Identifies a wizard session |
| `AgentName` | string (3-64 chars) | Proposed agent name, alphanumeric + hyphens, unique per namespace |
| `AgentDescription` | string (max 500) | Free-text agent description |
| `StepType` | Enum | DEFINE_IDENTITY, CONFIGURE_KNOWLEDGE, ASSIGN_TOOLS, REVIEW |
| `StepStatus` | Enum | PENDING, IN_PROGRESS, COMPLETED, ERROR |
| `KnowledgeSourceType` | Enum | FILE_UPLOAD, URL, RAW_TEXT |
| `KnowledgeSourceStatus` | Enum | PENDING, INGESTING, COMPLETED, FAILED |
| `CapabilityFlag` | Enum | CHAT, CODE_EXECUTION, WEB_SEARCH, FILE_PROCESSING, API_ORCHESTRATION |
| `ToolBindingId` | UUID | Identifier for a tool binding draft |
| `WizardSessionStatus` | Enum | ACTIVE, FINALIZED, EXPIRED, ABANDONED |

### Ubiquitous Language
- **Agent**: An AI-powered autonomous entity that performs tasks on behalf of a user
- **Agent Draft**: The in-progress wizard session capturing all partial agent configuration
- **Wizard Step**: A discrete phase in the multi-step creation flow
- **Knowledge Source**: A document, URL, or data source ingested into the agent's knowledge base
- **Tool Binding**: The association of a specific tool (API connector, function) with an agent, including configuration
- **Capability Profile**: The set of skills, tools, and permissions assigned to an agent
- **Ingestion**: The asynchronous process of parsing, chunking, and embedding knowledge source content
- **Finalization**: The completed wizard state that triggers handoff to AgentConfiguration context

## Bounded Context Integration Patterns

| Upstream Context | Downstream Context | Pattern | Integration |
|-----------------|-------------------|---------|-------------|
| **AgentCreation** | AgentConfiguration | Domain Event (async) | `AgentDraftFinalized` → AgentConfiguration creates Agent aggregate |
| **AgentCreation** | KnowledgeBase | Domain Event (async) + Polling | `KnowledgeSourcesSubmitted` → KnowledgeBase ingests; AgentCreation polls status |
| **AgentCreation** | ToolRegistry | Query (sync) | `GET /tools` and `GET /tools/{id}/schema` for tool catalog |
| **AgentCreation** | AuditTrail | Domain Event (async) | All wizard events logged for compliance |
| **AgentCreation** | WorkloadManagement | Domain Event (async) | Agent availability notification post-creation |
| **AgentCreation** | DiagnosticsService | Domain Event (async) | Ingestion SLA breaches and errors |

### Context Map

```
  ToolRegistry ──(query)──> AgentCreation ──(event)──> KnowledgeBase
                                  │
                           (event)│
                                  v
                         AgentConfiguration ──(event)──> WorkloadManagement
                                  │
                           (event)│
                                  v
                          DiagnosticsService
                                  │
                           (event)│
                                  v
                            AuditTrail
```

## Multi-Cloud & Data Residency Constraints

1. **Namespace Isolation**: Wizard sessions are scoped to a user's namespace. Agent names must be unique within the namespace.
2. **Knowledge Storage**: Knowledge source content is stored in cloud-agnostic object storage via MultiCloudAdapter. Actual backends: AWS S3, Azure Blob, GCP Cloud Storage.
3. **Data Residency**: Knowledge content must remain within the user's designated cloud region. Cross-cloud knowledge transfer is prohibited unless explicitly configured.
4. **Secret Handling**: Tool configurations that reference secrets (e.g., API keys) must use secret references (not plaintext) via the MultiCloudAdapter's unified secret abstraction.
5. **Agent Deployment Targeting**: Post-creation, agents can be deployed to one or more cloud providers. Deployment configuration is captured in the AgentConfiguration context (future story).

## API Endpoints (Draft)

| Method | Path | Description |
|--------|------|-------------|
| POST | /api/v1/wizard | Create new wizard session |
| GET | /api/v1/wizard/{sessionId} | Get current wizard state |
| PUT | /api/v1/wizard/{sessionId}/step/define-identity | Submit Step 1 data |
| PUT | /api/v1/wizard/{sessionId}/step/configure-knowledge | Submit Step 2 data |
| PUT | /api/v1/wizard/{sessionId}/step/assign-tools | Submit Step 3 data |
| GET | /api/v1/wizard/{sessionId}/knowledge-status | Poll knowledge ingestion status |
| GET | /api/v1/wizard/{sessionId}/review | Get Step 4 review summary |
| POST | /api/v1/wizard/{sessionId}/finalize | Finalize agent creation |
| DELETE | /api/v1/wizard/{sessionId} | Abandon wizard session |

## Validation Rules
| Field | Rule |
|-------|------|
| agentName | Required, 3-64 chars, alphanumeric + hyphens, unique per namespace |
| agentDescription | Optional, max 500 chars |
| capabilities | Required, at least one, must be from enum |
| knowledgeSources | At least 1, max 10 per agent |
| File size | Max 10 MB per file |
| Accepted MIME types | text/plain, text/markdown, application/pdf, text/csv, application/json |
| toolBindings | At least 1, toolId must exist in ToolRegistry, config must pass schema validation |
| Concurrent sessions | Max 5 per user |
| Session timeout | 24 hours of inactivity |

## Error Handling
| Error | HTTP Status | Description |
|-------|-------------|-------------|
| SessionNotFound | 404 | Wizard session ID does not exist |
| SessionExpired | 410 Gone | Session expired after 24h inactivity |
| ConcurrentSessionLimit | 429 | User has reached max 5 concurrent sessions |
| ValidationError | 400 | Input validation failed (details in response body) |
| ToolNotFound | 404 | Referenced toolId not found in ToolRegistry |
| ToolConfigInvalid | 400 | Tool configuration failed schema validation |
| IngestionFailed | 422 | Knowledge source ingestion could not be initiated |
| StepConflict | 409 | Attempting to submit data for wrong step |

## Non-Functional Requirements
- Wizard session timeout: 24 hours
- Max concurrent wizard sessions per user: 5
- API response time: < 500ms (p99)
- Eventual consistency for agent creation: < 5 seconds
- Knowledge ingestion SLA: < 30 seconds per source (excluding large files)
- All events persisted to AuditTrail

## Related Issues / Dependencies
- Depends on: **ToolRegistry** API (for tool catalog and schemas)
- Depends on: **KnowledgeBase** ingestion pipeline
- Triggers: **AgentConfiguration** context for agent persistence
- Logs to: **AuditTrail** context
- Notifies: **WorkloadManagement** context of new agent availability
- Monitored by: **DiagnosticsService** context

---

## User Stories

### AGENTWIZ-01: User starts a new agent creation wizard session

**As a** platform user
**I want** to initiate a new agent creation wizard
**So that** I can begin the guided process of creating an AI agent

**Acceptance Criteria:**
```gherkin
Given the user is authenticated
When the user initiates the agent creation wizard
Then a new wizard session is created with a unique session ID
And the session is assigned to the user's namespace
And the session state is set to DEFINE_IDENTITY
And the user is presented with Step 1: DEFINE_IDENTITY
```

**Event Triggers:** `agentWizard.WizardSessionStarted` — Payload: {sessionId, userId, namespace, startedAt, expiresAt}. Owner: AgentCreation. Consumers: AuditTrail.

---

### AGENTWIZ-02: Concurrent session limit enforcement

**As a** platform user
**I want** to be prevented from exceeding the maximum number of concurrent wizard sessions
**So that** system resources are not exhausted by abandoned sessions

**Acceptance Criteria:**
```gherkin
Given the user already has 5 active wizard sessions
When the user attempts to initiate a new agent creation wizard
Then the request is rejected with HTTP 429 Too Many Requests
And an error message is returned indicating the user has reached the maximum of 5 concurrent sessions
```

**Event Triggers:** `agentWizard.WizardSessionLimitExceeded` — Payload: {userId, activeSessionCount}. Owner: AgentCreation. Consumers: AuditTrail.

---

### AGENTWIZ-03: User defines the agent identity in Step 1

**As a** platform user
**I want** to define the agent's name, description, and capabilities
**So that** the agent has a clear identity and purpose

**Acceptance Criteria:**
```gherkin
Given the wizard session is in DEFINE_IDENTITY state
When the user submits agentName "my-agent-1", agentDescription "A test agent", and capabilities ["CHAT", "WEB_SEARCH"]
Then the agent identity data is validated and stored in the session
And the session state advances to CONFIGURE_KNOWLEDGE
And the user is presented with Step 2: CONFIGURE_KNOWLEDGE

Examples:
| agentName | valid? | reason |
|-----------|--------|--------|
| "my-agent-1" | true | meets all constraints |
| "ab" | false | too short (< 3 chars) |
| "a-very-long-name-that-exceeds-sixty-four-character-maximum-length-test" | false | too long (> 64 chars) |
| "my agent!" | false | contains space and special character |
| "my-agent-1" (duplicate) | false | duplicates existing agent in namespace |
| "" | false | required field empty |
| [] (empty capabilities) | false | at least one capability required |
| ["CHAT", "INVALID"] | false | invalid capability enum value |
```

**Event Triggers:** `agentWizard.IdentityDefined` — Payload: {sessionId, agentName, agentDescription, capabilities[]}. Owner: AgentCreation. Consumers: AgentConfiguration (pre-validation), AuditTrail.

---

### AGENTWIZ-04: User configures knowledge sources in Step 2

**As a** platform user
**I want** to upload documents, provide URLs, or paste text as knowledge sources for the agent
**So that** the agent can be equipped with domain-specific knowledge

**Acceptance Criteria:**
```gherkin
Given the wizard session is in CONFIGURE_KNOWLEDGE state
When the user submits a knowledgeSources array with:
  | sourceType   | sourceUri                   | filename  | content (base64)  |
  |--------------|-----------------------------|-----------|-------------------|
  | FILE_UPLOAD  |                             | guide.pdf | <base64 data>     |
  | URL          | https://docs.example.com    |           |                   |
  | RAW_TEXT     |                             |           | "Hello world"     |
Then each source is validated against MIME type and size constraints
And the sources are stored in the session
And an async ingestion request is dispatched to KnowledgeBase context for each source
And the session state advances to ASSIGN_TOOLS
And the user is presented with Step 3: ASSIGN_TOOLS
```

**Event Triggers:**
- `agentWizard.KnowledgeSourcesSubmitted` — Payload: {sessionId, sources: [{sourceId, sourceType, sourceUri?, filename?, description?}]}. Owner: AgentCreation. Consumers: KnowledgeBase, AuditTrail.

---

### AGENTWIZ-05: Knowledge source validation in Step 2

**As a** platform user
**I want** to receive immediate validation errors if my knowledge sources don't meet requirements
**So that** I can correct issues before proceeding

**Acceptance Criteria:**
```gherkin
Given the wizard session is in CONFIGURE_KNOWLEDGE state
When the user submits an empty knowledgeSources array
Then the request is rejected with a validation error
And an error message indicates at least one knowledge source is required

When the user submits 11 knowledge sources
Then the request is rejected with a validation error
And an error message indicates a maximum of 10 sources is allowed

When the user submits a FILE_UPLOAD source with content size 11MB
Then the request is rejected with a validation error
And an error message indicates file size exceeds 10MB limit

When the user submits a FILE_UPLOAD source with MIME type application/zip
Then the request is rejected with a validation error
And an error message indicates the MIME type is not accepted

When the user submits a URL source without sourceUri
Then the request is rejected with a validation error
And an error message indicates sourceUri is required for URL type
```

**Event Triggers:** None (validation failure, no event emitted).

---

### AGENTWIZ-06: Knowledge ingestion status polling

**As a** platform user
**I want** to see the ingestion status of my knowledge sources
**So that** I know when they are ready for the agent

**Acceptance Criteria:**
```gherkin
Given the user has submitted knowledge sources in Step 2
And the ingestion process is in progress
When the user views the wizard status
Then the polling endpoint returns current ingestion status for each source
And status is one of: PENDING, INGESTING, COMPLETED, FAILED
And sources with FAILED status include an errorMessage
And the wizard does NOT advance to Step 3 until all sources are COMPLETED or handled (FAILED accepted with user acknowledgement)
```

**Event Triggers:** (Polling — no domain event; KnowledgeBase publishes status updates asynchronously.)

---

### AGENTWIZ-07: User assigns tools in Step 3

**As a** platform user
**I want** to select and configure tools from the ToolRegistry for my agent
**So that** the agent can perform actions through external integrations

**Acceptance Criteria:**
```gherkin
Given the wizard session is in ASSIGN_TOOLS state
And the user has fetched available tools from ToolRegistry
When the user submits toolBindings:
  | toolId            | enabled | configuration               |
  |-------------------|---------|-----------------------------|
  | "slack-notifier"  | true    | {"channel": "#alerts"}      |
  | "code-executor"   | false   | {"timeout": 30}             |
Then each toolBinding is validated against the ToolRegistry schema
And the tools are stored in the session
And the session state advances to REVIEW
And the user is presented with Step 4: REVIEW
```

**Event Triggers:** `agentWizard.ToolBindingsSubmitted` — Payload: {sessionId, toolBindings: [{toolId, configuration, enabled}]}. Owner: AgentCreation. Consumers: AuditTrail.

---

### AGENTWIZ-08: Tool binding validation in Step 3

**As a** platform user
**I want** to receive validation errors if my tool selections are invalid
**So that** I can correct tool configuration issues

**Acceptance Criteria:**
```gherkin
Given the wizard session is in ASSIGN_TOOLS state
When the user submits an empty toolBindings array
Then the request is rejected with a validation error
And an error message indicates at least one tool binding is required

When the user submits a toolBinding with toolId "non-existent-tool"
Then the request is rejected with a validation error
And an error message indicates the tool was not found in ToolRegistry

When the user submits a toolBinding with configuration that fails schema validation
Then the request is rejected with a validation error
And an error message indicates the schema validation failure details
```

**Event Triggers:** `agentWizard.ToolBindingValidationFailed` — Payload: {sessionId, toolId, validationErrors}. Owner: AgentCreation. Consumers: AuditTrail.

---

### AGENTWIZ-09: User reviews and finalizes the agent draft in Step 4

**As a** platform user
**I want** to review a complete summary of my agent before finalizing
**So that** I can confirm all configuration is correct

**Acceptance Criteria:**
```gherkin
Given the wizard session is in REVIEW state
And all knowledge sources have completed ingestion (or FAILED with user acknowledgement)
When the user views the review screen
Then a full summary of all four steps is displayed including: agent identity, knowledge sources, tool bindings
When the user clicks "Confirm"
Then the AgentDraftFinalized event is published
And the session state is set to FINALIZED
And the wizard session is marked for cleanup
And the user is redirected to agent creation status

When the user clicks "Back" to return to a previous step
Then the wizard navigates to the selected step with all previously saved data intact
When the user modifies data and submits
Then the session data is updated
And the session returns to REVIEW state
```

**Event Triggers:** `agentWizard.AgentDraftFinalized` — Payload: {sessionId, userId, namespace, agentName, agentDescription, capabilities[], knowledgeSources[], toolBindings[], finalizedAt}. Owner: AgentCreation. Consumers: AgentConfiguration, AuditTrail, WorkloadManagement.

---

### AGENTWIZ-10: Wizard session expires after 24 hours of inactivity

**As a** platform user
**I want** my inactive wizard sessions to expire automatically
**So that** system resources are not consumed by abandoned sessions

**Acceptance Criteria:**
```gherkin
Given a wizard session exists with sessionId "sess-123"
And the last activity timestamp is older than 24 hours
When the user attempts to submit data to any step
Then the request is rejected with HTTP 410 Gone
And an error message indicates the session has expired
And the session data is cleaned up

When an async ingestion callback arrives for an expired session
Then the callback is logged but the session data is discarded
```

**Event Triggers:** `agentWizard.WizardSessionExpired` — Payload: {sessionId, userId, namespace, expiredAt}. Owner: AgentCreation. Consumers: AuditTrail, WorkloadManagement.

---

### AGENTWIZ-11: Knowledge ingestion completes asynchronously

**As a** KnowledgeBase context
**I want** to notify the AgentCreation context when ingestion completes or fails
**So that** the wizard can update source status and allow the user to proceed

**Acceptance Criteria:**
```gherkin
Given an ingestion request has been sent to KnowledgeBase for sourceId "src-456"
When the KnowledgeBase context completes ingestion
Then the KnowledgeBase publishes knowledge.IngestionCompleted event
And the AgentWizard context updates the source status to COMPLETED

When the KnowledgeBase context fails ingestion
Then the KnowledgeBase publishes knowledge.IngestionFailed event with error details
And the AgentWizard context updates the source status to FAILED
```

**Event Triggers:**
- `knowledge.IngestionCompleted` — Payload: {sessionId, sourceId, ingestedAt, contentHash}. Owner: KnowledgeBase. Consumers: AgentCreation, AuditTrail.
- `knowledge.IngestionFailed` — Payload: {sessionId, sourceId, errorMessage, failedAt}. Owner: KnowledgeBase. Consumers: AgentCreation, AuditTrail.

---

### AGENTWIZ-12: Agent configuration is completed after wizard finalization

**As a** AgentConfiguration context
**I want** to receive finalized agent drafts and create fully configured agents
**So that** agents become operational and available in the platform

**Acceptance Criteria:**
```gherkin
Given the AgentDraftFinalized event has been received by AgentConfiguration context
When the AgentConfiguration context processes the draft
Then the agent is created with all specified configuration
And the agent creation is completed within 5 seconds (eventual consistency SLA)
And the agent becomes available in the WorkloadManagement context
```

**Event Triggers:** `agentConfiguration.AgentCreated` — Payload: {agentId, agentName, namespace, capabilities[], knowledgeSourceIds[], toolBindingIds[], createdAt}. Owner: AgentConfiguration. Consumers: WorkloadManagement, AuditTrail, DiagnosticsService.

---

### AGENTWIZ-13: API response time meets sub-500ms SLA

**As a** platform user
**I want** the wizard API to respond quickly
**So that** the multi-step flow feels responsive

**Acceptance Criteria:**
```gherkin
Given the user submits a request to any wizard endpoint
When the request is processed
Then the API responds within 500 milliseconds (p99)
And the response includes appropriate status code and body
```

**Event Triggers:** None (performance SLA, not event-driven).

---

### AGENTWIZ-14: Knowledge ingestion meets 30-second SLA

**As a** platform engineer
**I want** knowledge source ingestion to complete within 30 seconds per source
**So that** users are not kept waiting unduly

**Acceptance Criteria:**
```gherkin
Given a knowledge source has been submitted for ingestion
When the KnowledgeBase context processes the source (excluding large files > 5MB)
Then the ingestion completes within 30 seconds
And if the SLA is exceeded, a warning is logged to AuditTrail
```

**Event Triggers:** `knowledge.IngestionSlaBreached` — Payload: {sessionId, sourceId, elapsedSeconds}. Owner: KnowledgeBase. Consumers: AuditTrail, DiagnosticsService.

---

### AGENTWIZ-15: All wizard events are logged to AuditTrail

**As a** compliance officer
**I want** all wizard-related events to be immutably logged
**So that** we have a complete audit trail of agent creation activities

**Acceptance Criteria:**
```gherkin
Given any wizard-related event is published
When the AuditTrail context receives the event
Then the event is persisted with: timestamp, eventType, sessionId, userId, namespace, payload
And the audit log is immutable and queryable
```

**Event Triggers:** Implicit — all events above are consumed by AuditTrail.

---

## Domain Events Catalog

| # | Event Name | Producer | Consumers | Payload (Key Fields) |
|---|-----------|----------|-----------|----------------------|
| 1 | `agentWizard.WizardSessionStarted` | AgentCreation | AuditTrail | sessionId, userId, namespace, startedAt, expiresAt |
| 2 | `agentWizard.WizardSessionLimitExceeded` | AgentCreation | AuditTrail | userId, activeSessionCount |
| 3 | `agentWizard.IdentityDefined` | AgentCreation | AgentConfiguration, AuditTrail | sessionId, agentName, agentDescription, capabilities[] |
| 4 | `agentWizard.IdentityUpdated` | AgentCreation | AuditTrail | sessionId, previousAgentName, updatedFields |
| 5 | `agentWizard.KnowledgeSourcesSubmitted` | AgentCreation | KnowledgeBase, AuditTrail | sessionId, sources[{sourceId, sourceType, sourceUri?, filename?, description?}] |
| 6 | `agentWizard.ToolBindingsSubmitted` | AgentCreation | AuditTrail | sessionId, toolBindings[{toolId, configuration, enabled}] |
| 7 | `agentWizard.ToolBindingValidationFailed` | AgentCreation | AuditTrail | sessionId, toolId, validationErrors |
| 8 | `agentWizard.AgentDraftFinalized` | AgentCreation | AgentConfiguration, AuditTrail, WorkloadManagement | sessionId, userId, namespace, agentName, agentDescription, capabilities[], knowledgeSources[], toolBindings[], finalizedAt |
| 9 | `agentWizard.WizardSessionExpired` | AgentCreation | AuditTrail, WorkloadManagement | sessionId, userId, namespace, expiredAt |
| 10 | `agentWizard.WizardStepNavigatedBack` | AgentCreation | AuditTrail | sessionId, fromStep, toStep |
| 11 | `knowledge.IngestionCompleted` | KnowledgeBase | AgentCreation, AuditTrail | sessionId, sourceId, ingestedAt, contentHash |
| 12 | `knowledge.IngestionFailed` | KnowledgeBase | AgentCreation, AuditTrail | sessionId, sourceId, errorMessage, failedAt |
| 13 | `knowledge.IngestionSlaBreached` | KnowledgeBase | AuditTrail, DiagnosticsService | sessionId, sourceId, elapsedSeconds |
| 14 | `agentConfiguration.AgentCreated` | AgentConfiguration | WorkloadManagement, AuditTrail, DiagnosticsService | agentId, agentName, namespace, capabilities[], knowledgeSourceIds[], toolBindingIds[], createdAt |

### Event Schema Standard
All events follow CloudEvents 1.0 specification:
```json
{
  "specversion": "1.0",
  "type": "com.rufkis.agentcreation.wizardsession.started",
  "source": "/rufkis/agent-creation",
  "id": "uuid-of-event",
  "time": "2025-01-01T00:00:00Z",
  "datacontenttype": "application/json",
  "data": { }
}
```
Event type format: `com.rufkis.{context}.{aggregate}.{eventName}`

## Design Decisions

### 1. Server-Side State Persistence
Wizard state is persisted server-side (PostgreSQL) rather than client-side. This enables:
- Multi-device continuity
- Async ingestion status tracking
- Session expiry enforcement
- Audit trail completeness

### 2. Event-Driven Handoff
The `AgentDraftFinalized` event is the sole handoff mechanism to AgentConfiguration. This decouples the wizard from agent provisioning and allows eventual consistency.

### 3. Asynchronous Knowledge Ingestion
Knowledge ingestion is fully asynchronous with polling. The wizard does not block on ingestion — users can proceed to Step 3 immediately while ingestion runs in the background. However, they cannot finalize until ingestion completes (or failures are acknowledged).

### 4. Concurrent Session Limit
The hard limit of 5 concurrent sessions per user prevents resource exhaustion from abandoned sessions while allowing reasonable multi-tasking.

### 5. 24-Hour Session Expiry
Sessions expire after 24 hours of inactivity. This balances user convenience (long-running wizard sessions) with resource cleanup.

### 6. Polling Over WebSocket for Ingestion
Polling is chosen over WebSocket for ingestion status to keep the architecture simple. If real-time updates become critical, this can be upgraded to WebSocket or Server-Sent Events.

### 7. CloudEvents Standard
All domain events follow the CloudEvents 1.0 specification for interoperability and future multi-cloud message routing.

## Questions / Open Items
- Should knowledge ingestion FAILURE block finalization, or should users be allowed to proceed without failed sources? (Decision: Blocked until user acknowledges failures)
- What is the data retention policy for expired/abandoned sessions? (Decision: 7 days after expiry, then purged)
- Should we support templates/pre-filled agents to accelerate creation? (Deferred to RUFKIS-06)
- How do we handle large file ingestion (>10MB, >30s SLA)? (Decision: Deferred — file splitting and parallel ingestion in future iteration)

## Test Scenarios
1. Create wizard session → session created in DEFINE_IDENTITY state.
2. Create wizard session when at concurrent limit → 429 returned.
3. Submit valid Step 1 data → transitions to CONFIGURE_KNOWLEDGE.
4. Submit invalid agent name → validation error returned.
5. Submit duplicate agent name → validation error returned.
6. Submit valid Step 2 data → ingestion initiated, transitions to ASSIGN_TOOLS.
7. Submit oversized file → validation error returned.
8. Submit unsupported MIME type → validation error returned.
9. Poll ingestion status → returns correct per-source status.
10. Submit valid Step 3 data → transitions to REVIEW.
11. Submit invalid tool binding → validation error returned.
12. View review summary → all data displayed correctly.
13. Navigate back from REVIEW to earlier step → previous data intact.
14. Confirm finalization → AgentDraftFinalized event published.
15. Attempt to use expired session → 410 Gone returned.
16. Ingestion completed callback → source status updated to COMPLETED.
17. Ingestion failed callback → source status updated to FAILED.
18. Agent created after finalization → appears in agent list within 5s.

---

## Changelog
| Date | Author | Change |
|------|--------|--------|
| 2026-06-02 | AgentBusinessAnalyst | Initial draft with full DDD analysis, 15 user stories, 14 domain events, bounded context definitions, and design decisions |
