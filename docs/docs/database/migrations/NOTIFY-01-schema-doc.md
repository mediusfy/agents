

# NOTIFY-01: Notification Ingestion Schema Documentation

## Story Reference
**NOTIFY-01**: Accept Notification Payload via REST API
**Bounded Context**: NotificationIngestion

## Gherkin Summary
```gherkin
Feature: Notification Ingestion
  Scenario: Valid notification is accepted
    Given the client submits a POST request to "/api/notify"
      And the request body is valid JSON containing fields "message" and "priority"
     When the request is processed
     Then the response status code is 201
      And the response body contains the "id" of the created notification record
```

## Domain Event
| Property     | Value                                  |
|-------------|----------------------------------------|
| **Event**   | `notification.NotificationSubmitted`   |
| **Version** | 1.0                                    |
| **Owner**   | NotificationIngestion Bounded Context  |
| **Payload** | `{ eventId, eventType, timestamp, data: { notificationId, message, priority, source, submittedAt } }` |
| **Consumers** | Future: NotificationDispatch, AuditLogging, BillingMetering, RateLimiting |

## Tables Created

### 1. `notifications` — Core notification records
| Column         | Type                    | Constraints                          | Description                                      |
|---------------|-------------------------|--------------------------------------|--------------------------------------------------|
| id            | UUID                    | PRIMARY KEY DEFAULT gen_random_uuid() | Unique identifier                               |
| message       | TEXT                    | NOT NULL, CHECK(TRIM != '')          | Notification message content                     |
| priority      | notification_priority   | NOT NULL                             | Enum: low, medium, high                          |
| source        | VARCHAR(255)            | NULLABLE                             | Origin system of the notification                |
| status        | notification_status     | NOT NULL DEFAULT 'created'           | Lifecycle: created, processing, completed, failed |
| submitted_at  | TIMESTAMPTZ             | NOT NULL DEFAULT NOW()               | Client-provided submission timestamp             |
| created_at    | TIMESTAMPTZ             | NOT NULL DEFAULT NOW()               | Database record creation timestamp               |
| updated_at    | TIMESTAMPTZ             | NOT NULL DEFAULT NOW()               | Last update timestamp (auto-managed via trigger) |

### 2. `outbox_events` — Transactional outbox
| Column          | Type          | Constraints                            | Description                                      |
|-----------------|---------------|----------------------------------------|--------------------------------------------------|
| id              | UUID          | PRIMARY KEY DEFAULT gen_random_uuid() | Unique identifier                                |
| aggregate_type  | VARCHAR(100)  | NOT NULL                              | e.g., "notification"                             |
| aggregate_id    | UUID          | NOT NULL                              | ID of the source aggregate                       |
| event_type      | VARCHAR(150)  | NOT NULL                              | e.g., "notification.NotificationSubmitted"       |
| event_version   | VARCHAR(10)   | NOT NULL DEFAULT '1.0'                | Schema version for deserialization               |
| event_payload   | JSONB         | NOT NULL                              | Full event payload                               |
| created_at      | TIMESTAMPTZ   | NOT NULL DEFAULT NOW()                | Creation timestamp (inside source transaction)   |
| published_at    | TIMESTAMPTZ   | NULLABLE                              | Timestamp when published to broker; NULL=pending |

## Enums

### `notification_priority`
- `low`
- `medium`
- `high`

### `notification_status`
- `created`
- `processing`
- `completed`
- `failed`

## Indexes

| Index Name                          | Table           | Columns                | Condition              | Purpose                          |
|-------------------------------------|-----------------|------------------------|------------------------|----------------------------------|
| idx_notifications_priority          | notifications   | priority               |                        | Filter by priority level         |
| idx_notifications_created_at        | notifications   | created_at DESC        |                        | Time-range queries, sorting      |
| idx_notifications_submitted_at      | notifications   | submitted_at DESC      |                        | Submission time queries          |
| idx_notifications_status            | notifications   | status                 |                        | Filter by lifecycle status       |
| idx_notifications_source            | notifications   | source                 | WHERE source IS NOT NULL | Lookup by source system        |
| idx_outbox_events_pending           | outbox_events   | created_at ASC, id ASC | WHERE published_at IS NULL | Outbox relay polling         |
| idx_outbox_events_aggregate         | outbox_events   | aggregate_type, aggregate_id |                   | Event tracing by aggregate       |

## Triggers

| Trigger Name                      | Table           | Event  | Function                    | Purpose                         |
|-----------------------------------|-----------------|--------|-----------------------------|---------------------------------|
| trg_notifications_updated_at      | notifications   | BEFORE UPDATE | update_modified_column() | Auto-set updated_at = NOW()   |
| trg_outbox_events_updated_at      | outbox_events   | BEFORE UPDATE | update_modified_column() | Auto-set updated_at = NOW()   |

## Stored Procedure

### `insert_notification_with_outbox(message, priority, source, submitted_at)`
Atomic helper that inserts a notification record AND its corresponding outbox event in a single transaction. Returns `(notification_id, outbox_id)`.

## Transactional Outbox Pattern

This migration implements the **Transactional Outbox Pattern** to guarantee reliable event publishing:

1. **Atomic Write**: The HTTP handler calls `insert_notification_with_outbox()` within a single DB transaction.
2. **Outbox Relay**: A separate background process (to be implemented in a future story) polls `outbox_events WHERE published_at IS NULL`, publishes each event to the message broker (e.g., Kafka, NATS, RabbitMQ), and sets `published_at`.
3. **Fault Tolerance**: If the broker is unavailable, events remain in the outbox table and are retried. No data loss.
4. **Exactly-Once Delivery**: The relay uses the `id` of each outbox row to deduplicate on the broker side (idempotent producer).

## Redis Cache Configuration

| Setting      | Value                          |
|-------------|--------------------------------|
| Key Pattern | `notification:{id}`            |
| TTL         | 300 seconds (5 minutes)        |
| Eviction    | allkeys-lru                    |
| Max Memory  | 128 MB                         |
| Persistence | RDB snapshots                  |

**File**: `docs/database/redis/NOTIFY-01-cache.conf`

## Check Constraints

| Constraint Name                          | Table           | Condition                     | Purpose                              |
|------------------------------------------|-----------------|-------------------------------|--------------------------------------|
| chk_notifications_message_not_empty      | notifications   | LENGTH(TRIM(message)) > 0    | Prevent empty/whitespace-only messages |
| chk_notifications_priority_valid         | notifications   | priority IN ('low','medium','high') | Belt-and-suspenders with enum   |

## Migration Files

| File | Path |
|------|------|
| Up Migration | `generated-app/default/database/migrations/002_notify-01_notifications.up.sql` |
| Down Migration | `generated-app/default/database/migrations/002_notify-01_notifications.down.sql` |
| Seed Data | `generated-app/default/database/seeds/002_notify-01_notifications_seed.sql` |
| Redis Config | `docs/database/redis/NOTIFY-01-cache.conf` |

## Related ADRs
- **ADR-002**: Notification Service Architecture — defines hexagonal layout, outbox pattern, correlation ID middleware, and priority as value object.
