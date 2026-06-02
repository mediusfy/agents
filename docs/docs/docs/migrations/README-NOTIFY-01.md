

# NOTIFY-01: Accept Notification Payload via REST API

## Overview

Create the database schema supporting the `POST /api/notify` endpoint. This includes:
- `notification_priority` enum (`low`, `medium`, `high`)
- `notification_status` enum (`created`, `processing`, `completed`, `failed`)
- `notifications` table with check constraints, indexes, and auto-updating timestamps
- `outbox_events` table implementing the Transactional Outbox Pattern
- Atomic stored procedure `insert_notification_with_outbox()` for single-transaction writes
- Redis cache configuration with 5-minute TTL

## Migration

```bash
# Apply
psql $DATABASE_URL -f database/migrations/002_notify-01_notifications.up.sql

# Revert
psql $DATABASE_URL -f database/migrations/002_notify-01_notifications.down.sql

# Seed
psql $DATABASE_URL -f database/seeds/002_notify-01_notifications_seed.sql
```

## Domain Event

**Event**: `notification.NotificationSubmitted` (v1.0)

```json
{
  "eventId": "550e8400-e29b-41d4-a716-446655440000",
  "eventType": "notification.NotificationSubmitted",
  "timestamp": "2025-03-21T10:30:00Z",
  "data": {
    "notificationId": "550e8400-e29b-41d4-a716-446655440001",
    "message": "Order #1234 has shipped",
    "priority": "high",
    "source": "order-service",
    "submittedAt": "2025-03-21T10:30:00Z"
  }
}
```

## Key Design Decisions

1. **Transactional Outbox**: The notification record and the outbox entry are written atomically in the same DB transaction. This prevents event loss if the broker is down.
2. **Stored Procedure**: `insert_notification_with_outbox()` encapsulates the atomic write, simplifying the Go HTTP handler.
3. **Enum Types**: PostgreSQL native enums for priority ensure data integrity and enable future extensions (e.g., adding "urgent").
4. **Partial Index**: The outbox relay uses `idx_outbox_events_pending` which only indexes unpublished events — efficient polling.
5. **Check Constraints**: Database-level validation for non-empty messages provides defense-in-depth beyond application validation.

## Cache Strategy

- **Key**: `notification:{id}`
- **TTL**: 5 minutes
- **Eviction**: allkeys-lru
- Cache is populated on POST response and invalidated on status updates.

## Consumers (Future)

| Consumer | Purpose |
|----------|---------|
| NotificationDispatch | Deliver notification via email/SMS/push |
| AuditLogging | Immutable audit trail for compliance |
| BillingMetering | Usage metering for billing |
| RateLimiting | Track submission rates per source |
