# Domain-Driven Design Analysis: Notification Ingestion Service

## Overview
A single POST `/api/notify` endpoint that accepts, validates, persists notifications to PostgreSQL, and returns a 201 with the created record ID.

---

## Bounded Contexts

### 1. NotificationIngestion (Core Domain)
| Aspect | Detail |
|---|---|
| **Name** | `NotificationIngestion` |
| **Responsibility** | Receive, validate, and persist notification payloads |
| **Owns** | `POST /api/notify`, validation rules, `notifications` table |

#### Ubiquitous Language
| Term | Definition |
|---|---|
| **Notification** | An aggregate root representing a message with a priority level to be stored and potentially dispatched downstream |
| **Message** | The free-text body/content of the notification (string, required, non-empty) |
| **Priority** | The importance level; must be one of `low`, `medium`, `high` |
| **Ingestion** | The end-to-end process: receiving the HTTP request → validating → persisting → responding |
| **Validation** | Business rules applied to the raw input before persistence |
| **NotificationRecord** | The persisted entity in PostgreSQL with fields `id` (UUID), `message` (TEXT), `priority` (TEXT), `created_at` (TIMESTAMP) |

#### Integration Patterns
Since `NotificationIngestion` is the **only bounded context** in the current scope, no inter-context integration patterns are required yet. However, **domain events** (see below) are published for future consumption by:

- `NotificationDispatch` (future) — channel routing (email, SMS, push)
- `AuditLogging` (future) — compliance trail
- `BillingMetering` (future) — usage-based billing
- `RateLimiting` (future) — quota enforcement

These future contexts should consume via an **event-driven anti-corruption layer (ACL)** to decouple schemas.

---

## Multi-Cloud & Data Residency Constraints

> **Note:** The current requirements do not specify a multi-cloud or regional deployment topology. The following flags are captured for future refinement:

| Constraint | Impact | Mitigation |
|---|---|---|
| **Data Residency** | If deployed across regions (e.g., EU, US), the `notifications` table content (especially `message` text) may contain PII subject to GDPR/CCPA | The `NotificationIngestion` context must be deployed regionally with a tenant/region routing layer in front of the API. PostgreSQL instance must be region-pinned. |
| **Regional Latency** | Cross-region synchronous DB writes would add 100-300ms latency | Keep PostgreSQL writes **regional** (same-region). If a future requirement demands global aggregation, use async CDC (Debezium) to a central data lake. ⚠️ **Flag:** A single global PostgreSQL instance is NOT acceptable. |
| **Cloud Provider Lock-in** | Native PostgreSQL (RDS, CloudSQL, Azure DB) each have slightly different failover behaviors | Use standard PostgreSQL 15+ with no vendor-specific extensions. Prefer managed services with PostgreSQL-compatible wire protocol. |

---

## User Stories

### NOTIFY-01: Accept Notification Payload via REST API
**As a** client application
**I want** to submit a notification via `POST /api/notify`
**So that** the system accepts, validates, and stores my notification payload, returning a unique identifier

```gherkin
Feature: Notification Ingestion
  Scenario: Valid notification is accepted
    Given the client submits a POST request to "/api/notify"
      And the request body is valid JSON containing fields "message" and "priority"
     When the request is processed
     Then the response status code is 201
      And the response body contains the "id" of the created notification record
```

**Maps to event:** `notification.NotificationSubmitted`

---

### NOTIFY-02: Validate Input Fields
**As a** system safeguard
**I want** to strictly validate all input fields before persistence
**So that** malformed or invalid payloads are rejected early with clear error responses

```gherkin
Feature: Input Validation
  Scenario: Missing message field is rejected
    Given the client submits a POST request to "/api/notify"
      And the JSON body contains "priority" but no "message" field
     When the request is processed
     Then the response status code is 400
      And the response body indicates "message is required"

  Scenario: Empty message string is rejected
    Given the client submits a POST request to "/api/notify"
      And "message" is an empty string
     When the request is processed
     Then the response status code is 400
      And the response body indicates "message must not be empty"

  Scenario: Invalid priority value is rejected
    Given the client submits a POST request to "/api/notify"
      And "priority" is set to "urgent" (not in allowed set)
     When the request is processed
     Then the response status code is 400
      And the response body indicates "priority must be one of: low, medium, high"

  Scenario: Malformed JSON is rejected
    Given the client submits a POST request to "/api/notify"
      And the request body is not valid JSON
     When the request is processed
     Then the response status code is 400
      And the response body indicates "invalid JSON payload"
```

**Maps to events:** `notify.ValidationFailed`, `notify.MalformedPayloadReceived`

---

### NOTIFY-03: Persist Notification to PostgreSQL
**As a** notification ingestion handler
**I want** to persist the validated notification to the `notifications` table
**So that** the record is durably stored and a unique ID is returned to the caller

```gherkin
Feature: Database Persistence
  Scenario: Valid notification is persisted
    Given a valid notification payload has passed input validation
     When the system attempts to insert the record into the "notifications" table
     Then the record is successfully committed
      And the record contains fields: id (UUID), message (text), priority (text), created_at (timestamp)
      And the generated id is returned in the 201 response

  Scenario: Database write failure is handled
    Given the PostgreSQL connection is unavailable or a write constraint is violated
     When the system attempts to insert the record
     Then the response status code is 500
      And the response body indicates "internal server error"
```

**Maps to events:** `notification.NotificationPersisted`, `notification.NotificationPersistenceFailed`

---

## Event Triggers

| Event Name | Owner (BC) | Trigger Condition | Consumers | Payload Schema (sketch) |
|---|---|---|---|---|
| **`notification.NotificationSubmitted`** | `NotificationIngestion` | Valid JSON with `message` & `priority` accepted, record persisted, 201 returned | Future: `NotificationDispatch`, `AuditLogging`, `BillingMetering`, `RateLimiting` | `{ eventId, eventType, timestamp, data: { notificationId, message, priority, source, submittedAt } }` |
| **`notify.ValidationFailed`** | `NotificationIngestion` | Valid JSON fails business validation (missing field, empty string, invalid enum) | `SecurityAudit`, `ObservabilityPipeline`, `APIGatewayAnalytics` | `{ eventId, eventType, timestamp, data: { reason, field, providedValue, remoteAddr } }` |
| **`notify.MalformedPayloadReceived`** | `NotificationIngestion` | Request body cannot be parsed as JSON | `SecurityAudit`, `APIGateway`, `ObservabilityPipeline` | `{ eventId, eventType, timestamp, data: { rawSnippet, remoteAddr, userAgent } }` |
| **`notification.NotificationPersisted`** | `NotificationIngestion` | Validated record successfully committed to `notifications` table | Future: `NotificationDispatch`, `ObservabilityPipeline` | `{ eventId, eventType, timestamp, data: { notificationId, message, priority, createdAt } }` |
| **`notification.NotificationPersistenceFailed`** | `NotificationIngestion` | PostgreSQL write fails (connection down, constraint violation) | `ObservabilityPipeline`, `SRE/OnCall` | `{ eventId, eventType, timestamp, data: { errorCode, errorMessage, dbInstance } }` |

---

## Ambiguities & Flags

| # | Flag | Recommendation |
|---|---|---|
| 1 | **Allowed priority values** are not explicitly defined | Assumed `low`, `medium`, `high`. Confirm with product owner. |
| 2 | **Max length** of `message` field not specified | Recommend 5000 chars as a reasonable initial limit. Enforce at validation layer. |
| 3 | **Multi-cloud / data residency** not addressed in requirements | Flagged above. If this service may handle PII, a region-pinned deployment with explicit data residency controls is mandatory. |
| 4 | **Authentication / Authorization** not mentioned | No auth is presumed for this scope. A future story should add API key or JWT validation. |
| 5 | **Rate limiting** not specified | No rate limiting in scope. Flagged as a future concern — the `notification.NotificationSubmitted` event feeds a rate limiter. |
