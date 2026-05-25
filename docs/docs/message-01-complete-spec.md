# MESSAGE-01: Message Ingestion — Complete Specification

## 1. User Story

**ID:** MESSAGE-01
**Title:** Message Ingestion
**Statement:** *As a* notification sender, *I want to* submit a notification message to the ingestion endpoint, *so that* it can be durably persisted, idempotency-checked, and queued for downstream processing.

---

## 2. Gherkin Acceptance Criteria (4 Scenarios)

### Scenario 1: Happy Path — Valid notification ingested successfully
```gherkin
Given a valid notification payload containing all required fields:
  | Field            | Example Value                        |
  |------------------|--------------------------------------|
  | notification_id  | "a1b2c3d4-e5f6-7890-abcd-ef1234567890" |
  | status           | "pending"                            |
  | channel          | "email"                              |
  | recipient        | "user@example.com"                   |
  | content          | {"subject": "Hello", "body": "World"} |
  | region_of_origin | "us-east-1"                          |
When the message ingestion endpoint receives a POST request to /api/v1/notifications
Then the system responds with HTTP 202 Accepted
And the response body contains a `notification_id` matching the submitted value
And the response body contains a `status_url` pointing to /api/v1/notifications/{notification_id}/status
And the system emits a `messaging.NotificationStatusReceived` domain event with status "received"
And the message is persisted to the `incoming_messages` table with a unique `dedup_key`
```

### Scenario 2: Duplicate Notification — Idempotency Enforcement
```gherkin
Given a notification with notification_id "a1b2c3d4-e5f6-7890-abcd-ef1234567890" and status "pending" has already been ingested
When the message ingestion endpoint receives a second POST request with identical notification_id and status "pending"
Then the system responds with HTTP 200 OK (not 202)
And the response body indicates this is a duplicate with `duplicate: true`
And no new `NotificationStatusReceived` event is emitted for this duplicate
And no additional row is inserted into the `incoming_messages` table
```

### Scenario 3: Missing Required Fields — Validation Failure
```gherkin
Given a notification payload missing the "recipient" field
When the message ingestion endpoint receives a POST request
Then the system responds with HTTP 422 Unprocessable Entity
And the response body contains a `validation_errors` array
And each error object includes `field`, `code`, and `message`
And the system emits a `messaging.NotificationStatusFailed` domain event with failure_reason "validation_error"
```

### Scenario 4: System Error — Downstream Failure
```gherkin
Given the database is unavailable
When the message ingestion endpoint receives a valid POST request
Then the system responds with HTTP 500 Internal Server Error
And the system routes the message to the dead_letter_queue table
And the dead_letter_queue entry captures the original payload, error_context, and a timestamp
And the system emits a `messaging.NotificationStatusFailed` domain event with failure_reason "system_error"
```

---

## 3. Incoming Message Payload Field Definitions

### Required Fields (REST POST body to `/api/v1/notifications`)

| # | Field              | Type      | Required | Constraints                                                         |
|---|--------------------|-----------|----------|---------------------------------------------------------------------|
| 1 | `notification_id`  | string    | **YES**  | Must be a valid UUIDv4; immutable once set                          |
| 2 | `status`           | string    | **YES**  | Must be one of: `pending`, `received`, `processing`, `completed`, `failed`; initial value for MESSAGE-01 is `"pending"` |
| 3 | `channel`          | string    | **YES**  | Must be one of: `email`, `sms`, `push`, `in_app`                    |
| 4 | `recipient`        | string    | **YES**  | Max length 512 chars; format validated by channel (email regex for `email`, E.164 regex for `sms`) |
| 5 | `content`          | object    | **YES**  | Must be a valid JSON object; max depth 10; max serialized size 64KB |
| 6 | `region_of_origin` | string    | **YES**  | Must match an allowed region code; see multi-cloud constraints below |

### Optional Fields

| # | Field              | Type      | Required | Constraints                                                         |
|---|--------------------|-----------|----------|---------------------------------------------------------------------|
| 7 | `metadata`         | object    | optional | Free-form JSON object; max 10KB; no PII allowed                     |
| 8 | `correlation_id`   | string    | optional | If provided, must be valid UUIDv4; used for distributed tracing    |
| 9 | `ttl_seconds`      | integer   | optional | If provided, must be 60–604800 (1 min to 7 days); default: 86400   |
| 10| `priority`         | integer   | optional | Must be 1 (highest)–5 (lowest); default: 3                         |
| 11| `schedule_at`      | string    | optional | ISO 8601 UTC timestamp; must be in the future if provided           |

### Full JSON Schema (REST Request Body)

```json
{
  "type": "object",
  "required": ["notification_id", "status", "channel", "recipient", "content", "region_of_origin"],
  "properties": {
    "notification_id":  { "type": "string", "format": "uuid", "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$" },
    "status":           { "type": "string", "enum": ["pending", "received", "processing", "completed", "failed"] },
    "channel":          { "type": "string", "enum": ["email", "sms", "push", "in_app"] },
    "recipient":        { "type": "string", "maxLength": 512 },
    "content":          { "type": "object", "maxProperties": 50 },
    "region_of_origin": { "type": "string", "enum": ["us-east-1", "us-west-2", "eu-west-1", "eu-central-1", "ap-southeast-1", "ap-northeast-1"] },
    "metadata":         { "type": "object", "maxProperties": 20 },
    "correlation_id":   { "type": "string", "format": "uuid" },
    "ttl_seconds":      { "type": "integer", "minimum": 60, "maximum": 604800 },
    "priority":         { "type": "integer", "minimum": 1, "maximum": 5 },
    "schedule_at":      { "type": "string", "format": "date-time" }
  },
  "additionalProperties": false
}
```

---

## 4. Composite Idempotency Key Specification

### Dedup Key Definition

The **dedup_key** is a composite, SHA-256 hash of the concatenation of:
```
dedup_key = SHA256( LOWER(TRIM(notification_id)) || '::' || LOWER(TRIM(status)) )
```

| Component         | Value                        | Notes                                              |
|-------------------|------------------------------|----------------------------------------------------|
| `notification_id` | `"a1b2c3d4-..."`             | Lowercased and trimmed before hashing              |
| Separator         | `"::"`                       | Double-colon delimiter                             |
| `status`          | `"pending"`                  | Lowercased and trimmed before hashing              |
| Output            | `"aB12..."` (64 hex chars)   | SHA-256 produces a 256-bit / 32-byte / 64-char hex |

### Database Enforcement

```sql
-- The dedup_key column:
dedup_key VARCHAR(64) NOT NULL,

-- UNIQUE constraint for idempotency:
CONSTRAINT uq_messages_dedup_key UNIQUE (dedup_key),

-- Index for fast dedup lookups:
CREATE INDEX idx_messages_dedup_key ON incoming_messages (dedup_key);
```

### Business Rule
- A row with `(notification_id='X', status='pending')` prevents insert of a second row with the same `(X, pending)`.
- A row with `(notification_id='X', status='completed')` is a **different** dedup_key and is allowed alongside the `pending` row.
- This allows state-machine progression (pending → received → processing → completed/failed) while preventing duplicate submissions of the same state.

---

## 5. Domain Events

### Event 1: `messaging.NotificationStatusReceived`

| Property         | Value                                  |
|------------------|----------------------------------------|
| **Owner BC**     | Messaging Context                      |
| **Consumers**    | Notification Delivery Context, Monitoring Context |
| **Trigger**      | Successful ingestion of a valid notification |

**Full JSON Schema:**
```json
{
  "specversion":     "1.0",
  "type":            "messaging.NotificationStatusReceived",
  "source":          "/messaging/ingestion",
  "id":              "evt-<uuid>",
  "time":            "2025-01-01T00:00:00Z",
  "datacontenttype": "application/json",
  "data": {
    "notification_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "status":          "received",
    "channel":         "email",
    "recipient":       "user@example.com",
    "region_of_origin": "us-east-1",
    "correlation_id":  "c1d2e3f4-...",
    "received_at":     "2025-01-01T00:00:00.123456Z",
    "metadata": {
      "original_status": "pending",
      "ingestion_host":  "ingestion-1.us-east-1"
    }
  }
}
```

### Event 2: `messaging.NotificationStatusFailed`

| Property         | Value                                  |
|------------------|----------------------------------------|
| **Owner BC**     | Messaging Context                      |
| **Consumers**    | Notification Delivery Context, Monitoring Context, Dead Letter Queue consumer |
| **Trigger**      | Ingestion failure (validation error or system error) |

**Full JSON Schema:**
```json
{
  "specversion":     "1.0",
  "type":            "messaging.NotificationStatusFailed",
  "source":          "/messaging/ingestion",
  "id":              "evt-<uuid>",
  "time":            "2025-01-01T00:00:00Z",
  "datacontenttype": "application/json",
  "data": {
    "notification_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "status":          "failed",
    "channel":         "email",
    "recipient":       "user@example.com",
    "region_of_origin": "us-east-1",
    "failure_reason":  "validation_error",
    "failure_code":    "MISSING_FIELD",
    "failure_detail":  "Required field 'recipient' is missing",
    "validation_errors": [
      { "field": "recipient", "code": "REQUIRED", "message": "recipient is required" }
    ],
    "correlation_id":  "c1d2e3f4-...",
    "failed_at":       "2025-01-01T00:00:00.123456Z",
    "metadata": {
      "original_payload": { ... },
      "ingestion_host":   "ingestion-1.us-east-1"
    }
  }
}
```

---

## 6. Field-Level Validation Rules

| Field              | Rule                                                                 | Error Code          | HTTP Status |
|--------------------|----------------------------------------------------------------------|---------------------|-------------|
| `notification_id`  | Must be a valid UUIDv4; regex: `^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$` | `INVALID_UUID`      | 422 |
| `status`           | Must be one of: `pending`, `received`, `processing`, `completed`, `failed` | `INVALID_STATUS`    | 422 |
| `channel`          | Must be one of: `email`, `sms`, `push`, `in_app`                     | `INVALID_CHANNEL`   | 422 |
| `recipient`        | Max 512 chars; if channel=`email`: must match email regex; if channel=`sms`: must match E.164 regex | `INVALID_RECIPIENT` | 422 |
| `content`          | Must be valid JSON object; max depth 10; max serialized size 64KB    | `INVALID_CONTENT`   | 422 |
| `region_of_origin` | Must be in allowed list: `us-east-1`, `us-west-2`, `eu-west-1`, `eu-central-1`, `ap-southeast-1`, `ap-northeast-1` | `INVALID_REGION`    | 422 |
| `metadata`         | Max 10KB serialized; must not contain nested PII (phone, email, SSN) | `INVALID_METADATA`  | 422 |
| `correlation_id`   | If provided, must be valid UUIDv4                                    | `INVALID_CORRELATION_ID` | 422 |
| `ttl_seconds`      | If provided, must be integer 60–604800                               | `INVALID_TTL`       | 422 |
| `priority`         | If provided, must be integer 1–5                                     | `INVALID_PRIORITY`  | 422 |
| `schedule_at`      | If provided, must be ISO 8601 UTC timestamp in the future            | `INVALID_SCHEDULE`  | 422 |
| Payload (global)   | Additional properties beyond the defined schema are rejected         | `UNEXPECTED_FIELD`  | 422 |

---

## 7. Multi-Cloud Data Residency Constraints

### Allowed Regions

| Region Code        | Cloud Provider   | Geographic Boundary            | Data Residency Law     |
|--------------------|------------------|--------------------------------|------------------------|
| `us-east-1`        | AWS US East      | United States                  | US data only           |
| `us-west-2`        | AWS US West      | United States                  | US data only           |
| `eu-west-1`        | AWS EU (Ireland) | European Union                 | GDPR                   |
| `eu-central-1`     | AWS EU (Frankfurt)| European Union                | GDPR                   |
| `ap-southeast-1`   | AWS Asia (Singapore)| Southeast Asia               | Local laws apply       |
| `ap-northeast-1`   | AWS Asia (Tokyo) | Japan                          | Local laws apply       |

### Rules

1. **Mandatory field:** `region_of_origin` is **required** on every incoming message.
2. **PII containment:** All payload data (recipient, content, metadata) MUST remain within the database cluster corresponding to `region_of_origin`. No cross-region replication of PII is permitted.
3. **Routing enforcement:** The ingestion endpoint MUST reject any request with an unapproved `region_of_origin` with HTTP 422 `INVALID_REGION`.
4. **Database sharding hint:** The `region_of_origin` column serves as a partition key / sharding hint for the PostgreSQL schema.
5. **Audit trail:** All `notification_status_events` and `dead_letter_queue` entries MUST include `region_of_origin` to enable per-region compliance audits.

---

## 8. Database Tables (PostgreSQL Schema)

### 8.1 `notification_status_enum`

```sql
CREATE TYPE notification_status_enum AS ENUM (
    'pending',
    'received',
    'processing',
    'completed',
    'failed'
);
```

### 8.2 `incoming_messages` Table

```sql
CREATE TABLE incoming_messages (
    id                BIGSERIAL PRIMARY KEY,
    notification_id   UUID NOT NULL,
    status            notification_status_enum NOT NULL DEFAULT 'pending',
    channel           VARCHAR(20) NOT NULL,
    recipient         VARCHAR(512) NOT NULL,
    content           JSONB NOT NULL,
    region_of_origin  VARCHAR(30) NOT NULL,
    metadata          JSONB DEFAULT '{}',
    correlation_id    UUID,
    ttl_seconds       INTEGER DEFAULT 86400,
    priority          INTEGER DEFAULT 3 CHECK (priority BETWEEN 1 AND 5),
    schedule_at       TIMESTAMPTZ,
    dedup_key         VARCHAR(64) NOT NULL,
    received_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Idempotency enforcement
    CONSTRAINT uq_incoming_messages_dedup_key UNIQUE (dedup_key),

    -- Check constraints
    CONSTRAINT chk_incoming_messages_channel CHECK (channel IN ('email', 'sms', 'push', 'in_app')),
    CONSTRAINT chk_incoming_messages_region CHECK (region_of_origin IN ('us-east-1', 'us-west-2', 'eu-west-1', 'eu-central-1', 'ap-southeast-1', 'ap-northeast-1')),
    CONSTRAINT chk_incoming_messages_ttl CHECK (ttl_seconds IS NULL OR (ttl_seconds >= 60 AND ttl_seconds <= 604800))
);

-- Indexes
CREATE INDEX idx_incoming_messages_dedup_key ON incoming_messages (dedup_key);
CREATE INDEX idx_incoming_messages_notification_id ON incoming_messages (notification_id);
CREATE INDEX idx_incoming_messages_region ON incoming_messages (region_of_origin);
CREATE INDEX idx_incoming_messages_status ON incoming_messages (status);
CREATE INDEX idx_incoming_messages_received_at ON incoming_messages (received_at DESC);
CREATE INDEX idx_incoming_messages_correlation_id ON incoming_messages (correlation_id) WHERE correlation_id IS NOT NULL;

-- Auto-update updated_at trigger
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_incoming_messages_updated_at
    BEFORE UPDATE ON incoming_messages
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

### 8.3 `dead_letter_queue` Table

```sql
CREATE TABLE dead_letter_queue (
    id                BIGSERIAL PRIMARY KEY,
    notification_id   UUID NOT NULL,
    original_payload  JSONB NOT NULL,
    error_context     JSONB NOT NULL DEFAULT '{}',
    error_code        VARCHAR(100) NOT NULL,
    error_message     TEXT NOT NULL,
    failure_reason    VARCHAR(50) NOT NULL,
    region_of_origin  VARCHAR(30) NOT NULL,
    retry_count       INTEGER NOT NULL DEFAULT 0,
    max_retries       INTEGER NOT NULL DEFAULT 3,
    failed_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_retry_at     TIMESTAMPTZ,
    processed         BOOLEAN NOT NULL DEFAULT FALSE,
    processed_at      TIMESTAMPTZ,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_dlq_failure_reason CHECK (failure_reason IN ('validation_error', 'system_error', 'processing_error', 'timeout'))
);

-- Indexes
CREATE INDEX idx_dlq_notification_id ON dead_letter_queue (notification_id);
CREATE INDEX idx_dlq_region ON dead_letter_queue (region_of_origin);
CREATE INDEX idx_dlq_unprocessed ON dead_letter_queue (processed, failed_at) WHERE processed = FALSE;
CREATE INDEX idx_dlq_failure_reason ON dead_letter_queue (failure_reason);
```

### 8.4 `notification_status_events` Table (Outbox for Domain Events)

```sql
CREATE TABLE notification_status_events (
    id                BIGSERIAL PRIMARY KEY,
    event_id          UUID NOT NULL UNIQUE,
    event_type        VARCHAR(100) NOT NULL,
    notification_id   UUID NOT NULL,
    status            notification_status_enum NOT NULL,
    region_of_origin  VARCHAR(30) NOT NULL,
    payload           JSONB NOT NULL,
    published         BOOLEAN NOT NULL DEFAULT FALSE,
    published_at      TIMESTAMPTZ,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_event_type CHECK (event_type IN ('messaging.NotificationStatusReceived', 'messaging.NotificationStatusFailed'))
);

-- Indexes
CREATE INDEX idx_nse_unpublished ON notification_status_events (published, created_at) WHERE published = FALSE;
CREATE INDEX idx_nse_notification_id ON notification_status_events (notification_id);
CREATE INDEX idx_nse_event_type ON notification_status_events (event_type);
CREATE INDEX idx_nse_region ON notification_status_events (region_of_origin);
```

---

## 9. Idempotent Upsert Function

```sql
CREATE OR REPLACE FUNCTION upsert_incoming_message(
    p_notification_id   UUID,
    p_status            notification_status_enum,
    p_channel           VARCHAR(20),
    p_recipient         VARCHAR(512),
    p_content           JSONB,
    p_region_of_origin  VARCHAR(30),
    p_metadata          JSONB DEFAULT '{}',
    p_correlation_id    UUID DEFAULT NULL,
    p_ttl_seconds       INTEGER DEFAULT 86400,
    p_priority          INTEGER DEFAULT 3,
    p_schedule_at       TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE(
    action_taken        TEXT,
    notification_id_out UUID,
    dedup_key_out       VARCHAR(64),
    is_duplicate        BOOLEAN
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_dedup_key VARCHAR(64);
    v_existing_id BIGINT;
BEGIN
    -- Compute dedup_key
    v_dedup_key := encode(
        sha256(
            convert_to(
                LOWER(TRIM(p_notification_id::TEXT)) || '::' || LOWER(TRIM(p_status::TEXT)),
                'UTF8'
            )
        ),
        'hex'
    );

    -- Check for existing
    SELECT id INTO v_existing_id
    FROM incoming_messages
    WHERE dedup_key = v_dedup_key;

    IF v_existing_id IS NOT NULL THEN
        RETURN QUERY SELECT 'skipped'::TEXT, p_notification_id, v_dedup_key, true::BOOLEAN;
        RETURN;
    END IF;

    -- Insert new row
    INSERT INTO incoming_messages (
        notification_id, status, channel, recipient, content,
        region_of_origin, metadata, correlation_id, ttl_seconds,
        priority, schedule_at, dedup_key
    ) VALUES (
        p_notification_id, p_status, p_channel, p_recipient, p_content,
        p_region_of_origin, p_metadata, p_correlation_id, p_ttl_seconds,
        p_priority, p_schedule_at, v_dedup_key
    );

    RETURN QUERY SELECT 'inserted'::TEXT, p_notification_id, v_dedup_key, false::BOOLEAN;
END;
$$;
```

---

## 10. Event Trigger Summary for MESSAGE-01

| Event Name                              | Owner BC         | Consumers                                          | Trigger Condition               |
|-----------------------------------------|------------------|----------------------------------------------------|----------------------------------|
| `messaging.NotificationStatusReceived`  | Messaging        | Notification Delivery, Monitoring                  | Successful ingestion of valid msg |
| `messaging.NotificationStatusFailed`    | Messaging        | Notification Delivery, Monitoring, DLQ Consumer    | Validation or system error       |

---

## 11. HTTP Response Codes Summary

| Scenario                          | HTTP Status | Content-Type                        | Key Response Fields                                   |
|-----------------------------------|-------------|-------------------------------------|-------------------------------------------------------|
| Happy path (new, valid message)   | **202 Accepted** | `application/json`              | `notification_id`, `status_url`                        |
| Duplicate (idempotent re-submit)  | **200 OK**  | `application/json`                  | `notification_id`, `duplicate: true`                   |
| Validation failure (bad payload)  | **422 Unprocessable Entity** | `application/json` | `validation_errors: [{field, code, message}]`          |
| System error (DB unavailable)     | **500 Internal Server Error** | `application/json` | `error: "internal_error", message: "..."`              |
| Unauthorized / bad method         | **401 / 405** | `application/json`               | Standard error body                                    |
