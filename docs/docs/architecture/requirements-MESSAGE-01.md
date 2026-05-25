

# MESSAGE-01: Raw Incoming Message Ingestion

**Story ID:** MESSAGE-01  
**Title:** As a message processing service, I want to receive raw incoming messages so that I can process and route them downstream.  
**Bounded Context:** Messaging Context  
**Endpoint:** `POST /api/v1/messages`

---

## 1. Gherkin Acceptance Criteria

```gherkin
Feature: Incoming Message Ingestion

  Scenario: Successful message ingestion with valid payload
    Given a consumer sends an HTTP POST request to /api/v1/messages with a valid JSON payload
    When the Message Processing Service receives the request
    Then the service validates that all required fields are present
    And the service checks idempotency using the composite key (notification_id, status)
    And if the composite key already exists, the service returns HTTP 409 Conflict with no further processing
    And if the composite key is unique, the service persists the message to the messages table
    And the service emits a NotificationStatus domain event with status='received' and region_of_origin
    And the service returns HTTP 201 Created with the persisted message ID

  Scenario: Missing required fields
    Given a consumer sends an HTTP POST request to /api/v1/messages with a payload missing required fields
    When the Message Processing Service validates the payload
    Then the service returns HTTP 400 Bad Request with a list of missing required fields

  Scenario: Idempotency conflict (duplicate submission)
    Given a message with composite key (notification_id=X, status='pending') already exists in the messages table
    When a consumer sends another request with the same notification_id and status
    Then the service returns HTTP 409 Conflict
    And no duplicate message is persisted
    And no duplicate domain event is emitted

  Scenario: Data residency constraint enforcement
    Given a consumer sends an HTTP POST request to /api/v1/messages with a payload containing PII
    When the Message Processing Service validates data residency constraints
    Then the service enforces that region_of_origin is present and valid
    And the service tags the record for regional data residency compliance

  Scenario: Database persistence failure
    Given message persistence fails due to a database error
    When the service catches the exception
    Then the service writes the message to the dead_letter_queue table with the error details
    And the service emits a NotificationDetailsEvent with failure details and region_of_origin
    And the service returns HTTP 500 Internal Server Error
```

---

## 2. Incoming Message Payload / Field Definitions

### Request Body (`POST /api/v1/messages`)

```json
{
  "notification_id": "uuid-v4",
  "customer_id": "string",
  "channel": "email | sms | push | in_app",
  "status": "string (required, initial value: 'pending')",
  "content": {
    "subject": "string",
    "body": "string",
    "template_id": "string (optional)"
  },
  "priority": "low | normal | high (default: normal)",
  "region_of_origin": "us-east-1 | eu-west-1 | ap-southeast-1",
  "metadata": {
    "source_system": "string",
    "correlation_id": "uuid (optional)"
  },
  "ttl_seconds": "integer (optional, default: 604800)"
}
```

### Required Fields (validation enforces these)
| Field | Type | Description |
|-------|------|-------------|
| `notification_id` | UUID v4 | Unique identifier for the notification |
| `customer_id` | String | Target customer identifier |
| `channel` | Enum | Delivery channel (email/sms/push/in_app) |
| `status` | String | Message status (initial = "pending") |
| `content.body` | String | Message body content |
| `region_of_origin` | Enum | AWS region where this request originated |

### Optional Fields
| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `content.subject` | String | "" | Subject line (required for email) |
| `content.template_id` | String | null | Template reference |
| `priority` | Enum | "normal" | Processing priority |
| `metadata.source_system` | String | null | Originating system name |
| `metadata.correlation_id` | UUID | null | End-to-end tracing ID |
| `ttl_seconds` | Integer | 604800 | Message time-to-live (7 days) |

---

## 3. Idempotency Key Details

- **Composite Key:** `(notification_id, status)`
- **Enforcement:** UNIQUE constraint on `dedup_key` column in `messages` table, computed as `notification_id || '::' || status`
- **Conflict Response:** HTTP 409 Conflict
- **Duplicate Behavior:** On conflict, the service returns 409 and does NOT:
  - Persist a duplicate row
  - Emit any domain event
  - Update any existing row
- **Scope:** Per message ingestion only; idempotency for other state transitions uses `(notification_id, new_status)`

### PostgreSQL Table Constraint

```sql
CREATE TABLE messages (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    notification_id UUID NOT NULL,
    customer_id     TEXT NOT NULL,
    channel         TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending',
    content         JSONB NOT NULL,
    priority        TEXT NOT NULL DEFAULT 'normal',
    region_of_origin TEXT NOT NULL,
    dedup_key       TEXT NOT NULL GENERATED ALWAYS AS (notification_id::text || '::' || status) STORED,
    ttl_seconds     INTEGER NOT NULL DEFAULT 604800,
    metadata        JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_messages_dedup UNIQUE (dedup_key)
);
```

---

## 4. Domain Events on Message Ingestion

### Event 1: `messaging.NotificationStatusReceived`

| Property | Value |
|----------|-------|
| **Name** | `messaging.NotificationStatusReceived` |
| **Owner** | Messaging Context |
| **Consumers** | Notification Orchestrator, Analytics Service, Compliance Logger |
| **Trigger** | Successful persistence of a new, idempotent message |

**Payload Schema:**
```json
{
  "event_id": "uuid-v4",
  "event_type": "messaging.NotificationStatusReceived",
  "occurred_at": "2025-01-01T00:00:00Z",
  "region_of_origin": "us-east-1",
  "data": {
    "notification_id": "uuid",
    "message_id": "uuid",
    "customer_id": "string",
    "channel": "email",
    "status": "received",
    "priority": "normal",
    "payload_summary": {
      "has_subject": true,
      "body_length": 1024
    }
  }
}
```

### Event 2: `messaging.NotificationStatusFailed`

| Property | Value |
|----------|-------|
| **Name** | `messaging.NotificationStatusFailed` |
| **Owner** | Messaging Context |
| **Consumers** | Dead Letter Handler, Alerting/SRE Service, Audit Trail |
| **Trigger** | Database persistence failure (message routed to DLQ) |

**Payload Schema:**
```json
{
  "event_id": "uuid-v4",
  "event_type": "messaging.NotificationStatusFailed",
  "occurred_at": "2025-01-01T00:00:00Z",
  "region_of_origin": "us-east-1",
  "data": {
    "notification_id": "uuid",
    "status": "failed_ingestion",
    "original_payload": { },
    "error_details": {
      "code": "DB_WRITE_FAILURE",
      "message": "could not serialize access due to concurrent update",
      "stack_trace": "..."
    },
    "dlq_entry_id": "uuid"
  }
}
```

---

## 5. Validation Rules

### Field-Level Validation

| Rule | Logic | Error Code |
|------|-------|------------|
| **Required fields** | Reject if notification_id, customer_id, channel, content.body, or region_of_origin is null/missing | `MISSING_REQUIRED_FIELD` |
| **notification_id format** | Must be valid UUID v4 | `INVALID_UUID` |
| **channel enum** | Must be one of: `email`, `sms`, `push`, `in_app` | `INVALID_CHANNEL` |
| **region_of_origin** | Must be one of: `us-east-1`, `eu-west-1`, `ap-southeast-1` (aligned with deployment regions) | `INVALID_REGION` |
| **content.body length** | Max 100,000 characters | `PAYLOAD_TOO_LARGE` |
| **priority** | If provided, must be `low`, `normal`, or `high` | `INVALID_PRIORITY` |
| **ttl_seconds** | If provided, must be 60–2,592,000 (1 min – 30 days) | `INVALID_TTL` |
| **PII detection** | If content.body contains detected PII patterns, region_of_origin must be a valid GDPR/compliant region | `DATA_RESIDENCY_VIOLATION` |

### Idempotency Validation
- Compute `dedup_key = notification_id || '::' || status`
- If `dedup_key` exists → HTTP 409 Conflict → no processing
- If `dedup_key` does not exist → proceed with persistence

### Response Codes

| Scenario | HTTP Status | Body |
|----------|-------------|------|
| Success | `201 Created` | `{ "message_id": "uuid", "status": "received" }` |
| Validation failure | `400 Bad Request` | `{ "error": "MISSING_REQUIRED_FIELD", "fields": ["content.body"] }` |
| Idempotency conflict | `409 Conflict` | `{ "error": "DUPLICATE_MESSAGE", "existing_message_id": "uuid" }` |
| Persistence failure | `500 Internal Server Error` | `{ "error": "INTERNAL_ERROR", "trace_id": "uuid" }` |

---

## 6. Data Residency / Region Constraints

### Multi-Cloud / Regional Routing Rules

1. **`region_of_origin` is mandatory** — every incoming request must declare the AWS region of origin
2. **PII data must stay in-region** — if PII is detected in the payload, the message must be stored in a database instance within the declared `region_of_origin`
3. **Supported regions:**
   - `us-east-1` — US data residency
   - `eu-west-1` — EU/GDPR data residency
   - `ap-southeast-1` — Asia-Pacific data residency
4. **Cross-region routing is forbidden** — a message with `region_of_origin: "eu-west-1"` cannot be written to a `us-east-1` database
5. **Events carry `region_of_origin`** — all emitted events include `region_of_origin` so downstream consumers can enforce regional routing
6. **DLQ is per-region** — each regional deployment has its own dead letter queue; messages are never moved between regional DLQs

### Database-Level Enforcement

```sql
-- Messages table is region-partitioned (by schema or separate DB per region)
-- region_of_origin is stored and indexed for audit queries
CREATE INDEX idx_messages_region ON messages (region_of_origin);
```
