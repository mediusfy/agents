# Domain-Driven Design Analysis: Notification Ingestion Service

## 1. Bounded Contexts

### 1.1 Notifications (Core Domain)
**Ubiquitous Language:**
| Term | Definition |
|------|-----------|
| **Notification** | A discrete message payload with a `message` (string) and `priority` (enum: low, medium, high, critical) that requires ingestion and eventual delivery |
| **Notification Ingestion** | The process of accepting, validating, and persisting a raw notification before any routing or delivery logic occurs |
| **Priority** | A severity classification dictating delivery urgency. Valid values: `low`, `medium`, `high`, `critical` |
| **Ingestion Record** | The persisted representation of a notification in PostgreSQL, including an auto-generated UUID, the message, priority, and a creation timestamp |

**Owned Entities:**
- `Notification` (Aggregate Root) — fields: id, message, priority, created_at
- `NotificationIngestionService` (Domain Service) — validates and persists

**Integration with other contexts:**
- **→ Audit (Customer-Supplier):** Publishes `notifications.NotificationCreated` for compliance logging
- **→ Dispatch (Customer-Supplier):** Publishes `notifications.NotificationCreated` for routing to downstream channels (email, SMS, PagerDuty)
- **→ Alerting (Shared Kernel):** Consumes priority information to determine alert severity

### 1.2 Infrastructure / Platform (Supporting)
**Ubiquitous Language:**
| Term | Definition |
|------|-----------|
| **Database Unavailability** | A state where PostgreSQL cannot be reached or a write operation fails |
| **Ingestion Failure** | An unrecoverable error during notification persistence |

**Owned Events:**
- `infrastructure.DatabaseUnavailable` — cross-cutting infrastructure health signal

### 1.3 Audit (Generic Subdomain)
**Context Boundary:** Consumes `notifications.NotificationCreated` for immutable compliance logging.
**Integration Pattern:** Anti-Corruption Layer — Audit translates the notification event into its own immutable audit trail format.

### 1.4 Dispatch (Supporting)
**Context Boundary:** Consumes `notifications.NotificationCreated` and routes it based on priority to the appropriate delivery channel.
**Integration Pattern:** Customer-Supplier (Notifications is the Supplier).

---

## 2. User Stories

### NOTIF-01: Successfully create a valid notification via POST /api/notify
**As a** system client (internal service or API consumer),
**I want** to POST a JSON body with `message` and `priority` to `/api/notify`,
**So that** my notification is validated, stored in PostgreSQL, and I receive back a 201 response with the created record ID.

**Acceptance Criteria (Gherkin):**
```gherkin
Scenario: Create a notification with valid fields
  Given a valid request body with "message" = "Server CPU exceeded 90%" and "priority" = "high"
  When I send a POST request to "/api/notify" with the JSON body
  Then the response status code should be 201
  And the response body should contain the created "id" field as a non-null value
  And a record with that "id" should exist in the PostgreSQL "notifications" table
  And the stored "message" should equal "Server CPU exceeded 90%"
  And the stored "priority" should equal "high"
```

**Event Trigger:** `notifications.NotificationCreated`

---

### NOTIF-02: Reject request with missing required fields
**As a** system client,
**I want** to receive a 400 error when I omit `message` or `priority`,
**So that** I am aware of the required schema and no partial records are stored.

**Acceptance Criteria (Gherkin):**
```gherkin
Scenario: Missing "message" field
  Given a request body with "priority" = "low" but no "message" field
  When I send a POST request to "/api/notify" with the JSON body
  Then the response status code should be 400
  And the response body should contain an error description indicating "message" is required
  And no new record should be inserted into PostgreSQL

Scenario: Missing "priority" field
  Given a request body with "message" = "Test" but no "priority" field
  When I send a POST request to "/api/notify" with the JSON body
  Then the response status code should be 400
  And the response body should contain an error description indicating "priority" is required
  And no new record should be inserted into PostgreSQL

Scenario: Both fields missing
  Given a request body with no fields
  When I send a POST request to "/api/notify" with the JSON body
  Then the response status code should be 400
  And the response body should contain an error description mentioning both missing fields
  And no new record should be inserted into PostgreSQL
```

**Event Trigger:** None (validation failure is not a domain event — it's a client error handled at the API boundary)

---

### NOTIF-03: Reject request with invalid field types or values
**As a** system client,
**I want** to receive a 400 error when I provide fields with wrong types or invalid priority values,
**So that** I understand the schema constraints (string message, enum priority).

**Acceptance Criteria (Gherkin):**
```gherkin
Scenario: "message" is not a string
  Given a request body with "message" = 12345 and "priority" = "low"
  When I send a POST request to "/api/notify" with the JSON body
  Then the response status code should be 400
  And the response body should describe that "message" must be a string
  And no new record should be inserted into PostgreSQL

Scenario: "priority" is an invalid value
  Given a request body with "message" = "Test" and "priority" = "urgent"
  When I send a POST request to "/api/notify" with the JSON body
  Then the response status code should be 400
  And the response body should describe the allowed priority values (low, medium, high, critical)
  And no new record should be inserted into PostgreSQL

Scenario: Empty "message" string
  Given a request body with "message" = "" and "priority" = "medium"
  When I send a POST request to "/api/notify" with the JSON body
  Then the response status code should be 400
  And the response body should indicate "message" cannot be empty
  And no new record should be inserted into PostgreSQL
```

**Event Trigger:** None (validation failure — client error at boundary)

---

### NOTIF-04: Handle database write failure gracefully
**As a** system operator,
**I want** the API to return a 500 error when PostgreSQL is unavailable,
**So that** clients can implement retry logic and I can be alerted of infrastructure issues.

**Acceptance Criteria (Gherkin):**
```gherkin
Scenario: PostgreSQL is unreachable during insert
  Given the PostgreSQL database is unavailable
  And a valid request body with "message" = "Test" and "priority" = "low"
  When I send a POST request to "/api/notify" with the JSON body
  Then the response status code should be 500
  And the response body should contain an error message indicating a server error
  And no record should be persisted
```

**Event Triggers:**
- `notifications.NotificationIngestionFailed` — domain event for ingestion failure
- `infrastructure.DatabaseUnavailable` — infrastructure-level health event
- `notifications.NotificationLost` — definitive data loss event (triggered after retry exhaustion)

---

### NOTIF-05: Reject non-POST HTTP methods on /api/notify
**As a** system client,
**I want** to receive a 405 response when I send a non-POST request to `/api/notify`,
**So that** I am aware the endpoint is strictly for creation.

**Acceptance Criteria (Gherkin):**
```gherkin
Scenario: GET request to /api/notify
  Given the endpoint "/api/notify" exists
  When I send a GET request to "/api/notify"
  Then the response status code should be 405

Scenario: PUT request to /api/notify
  Given the endpoint "/api/notify" exists
  When I send a PUT request to "/api/notify" with a JSON body
  Then the response status code should be 405

Scenario: DELETE request to /api/notify
  Given the endpoint "/api/notify" exists
  When I send a DELETE request to "/api/notify"
  Then the response status code should be 405
```

**Event Trigger:** None (HTTP method mismatch is handled at the routing layer)

---

## 3. Event Triggers — Complete Catalog

| Event Name | Owner Context | Payload (Sketch) | Consumers | Triggered By |
|---|---|---|---|---|
| `notifications.NotificationCreated` | Notifications | `{ notificationId: UUID, message: string, priority: enum, createdAt: timestamp }` | Audit, Dispatch, Alerting, Analytics | NOTIF-01 (successful POST) |
| `notifications.NotificationIngestionFailed` | Notifications | `{ reason: string, originalPayload: object, timestamp: timestamp }` | Audit, Ops Alerting | NOTIF-04 (DB failure) |
| `infrastructure.DatabaseUnavailable` | Infrastructure | `{ service: string, operation: string, errorCode: string, timestamp: timestamp }` | SRE, Ops Alerting, Notifications | NOTIF-04 (DB connection failure) |
| `notifications.NotificationLost` | Notifications | `{ notificationId: UUID, originalPayload: object, reason: string, finalAttempt: timestamp }` | Audit, Compliance | NOTIF-04 (after retry exhaustion) |

---

## 4. Integration Patterns Between Contexts

```
┌──────────────────────┐     Event Bus     ┌──────────────────┐
│                      │──────────────────▶│      Audit       │
│    Notifications     │                   │ (ACL — Anti-     │
│   (Core Domain)      │──────────────────▶│  Corruption Layer)│
│                      │                   └──────────────────┘
│  POST /api/notify    │     Event Bus     ┌──────────────────┐
│  ───→ Validate       │──────────────────▶│     Dispatch     │
│  ───→ Persist        │                   │ (Customer-       │
│  ───→ Publish Event  │──────────────────▶│  Supplier)       │
│                      │     Event Bus     └──────────────────┘
│  Owns: Notification  │──────────────────▶┌──────────────────┐
│  (Aggregate Root)    │                   │    Alerting      │
└──────────────────────┘                   │ (Shared Kernel   │
                                           │  — Priority enum)│
                                           └──────────────────┘
```

**Key Architectural Decisions:**
1. **Event-first design** — Success/failure events are the contract between contexts
2. **Anti-Corruption Layer (Audit)** — Audit transforms notification events into its own immutable format, insulating it from changes in the Notifications context
3. **Customer-Supplier (Dispatch)** — Notifications guarantees the event contract; Dispatch adapts to it
4. **Shared Kernel (Alerting)** — The `priority` enum is shared between Notifications and Alerting; changes require coordination

---

## 5. Data Residency & Multi-Cloud Constraints

*This section documents constraints based on infrastructure requirements:*

- **Data Residency:** The `notifications` table stores potentially sensitive operational data. Deployment regions must comply with GDPR (EU), CCPA (California), LGPD (Brazil), etc.
- **Regional Isolation:** Notifications ingested in region `eu-west-1` must persist and emit events only within that region's PostgreSQL instance and event bus, unless explicitly forwarded by a cross-region dispatcher.
- **Latency Consideration:** The POST /api/notify endpoint must respond within <500ms P99. If the PostgreSQL instance is in a different cloud/region, network latency must be accounted for; a local write-ahead cache may be necessary.
