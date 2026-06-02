# NOTIF-01: Create Notification Schema

## Story
**NOTIF-01**: Create a notification with valid message and priority.

**GHERKIN**: Successfully create a notification with valid fields.
- A valid JSON body with "message" set to "Order #1234 has shipped" and "priority" set to "high"
- POST to "/api/notify"
- HTTP 201 response
- Record persisted in PostgreSQL "notifications" table
- "notifications.NotificationCreated" domain event published

## Domain Event
- **Event**: `notifications.NotificationCreated`
- **Payload**: `{ notificationId, message, priority, createdAt }`
- **Owned by**: Notifications Bounded Context
- **Consumers**: Audit.Logging, Analytics.Tracking, Delivery.Dispatch, UserPreferences

## Database Changes
- **Migration**: `002_notif-01_notifications.sql`
  - Creates `notification_priority` enum type
  - Creates `notifications` table with UUID PK, message, priority, and timestamps
  - Adds indexes on `priority` and `created_at`
  - Adds trigger for auto-updating `updated_at`

## Redis
- Caching enabled for notifications with TTL of 5 minutes
- Cache key pattern: `notification:{id}`
- Eviction policy: allkeys-lru
