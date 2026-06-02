

# NOTIF-02: Reject Notification Creation When Message Field is Missing or Invalid

## Story
**NOTIF-02**: Reject notification creation when message field is missing or invalid.

**GHERKIN**: Ensure all notifications stored in the database contain a valid, non-empty message.

## Domain Event
- **Event**: `notifications.NotificationCreated`
- **Payload**: `{ notificationId, priority, title, message, sourceEventType, sourceEventId, targetRoute, timestamp }`
- **Owned by**: Notifications Bounded Context
- **Consumers**: Notification store, Audit.Logging, Analytics.Tracking

## Database Changes
- **Migration**: `002_notif-02_message_check_constraint.sql` (up / down)
  - Adds `message` column (`TEXT`) to the `notifications` table
  - Backfills existing rows from `body` (or `title` as fallback)
  - Adds CHECK constraint `ck_notifications_message_not_empty`
    - Ensures `message IS NOT NULL AND message != ''`

## Validation Logic
- The CHECK constraint enforces at the database level that:
  - `message` cannot be NULL
  - `message` cannot be an empty string `''`
- This provides a hard database-level safeguard alongside application-level validation

## Existing Schema Context
Existing `notifications` table columns (from `001_initial_schema.up.sql`):
| Column | Type | Constraints |
|---|---|---|
| id | UUID | PK, DEFAULT gen_random_uuid() |
| user_id | UUID | NOT NULL |
| event_type | VARCHAR(255) | NOT NULL |
| title | VARCHAR(255) | NOT NULL |
| body | TEXT | NULLABLE |
| board_id | UUID | NULLABLE |
| resource_fingerprint | VARCHAR(255) | NULLABLE |
| is_read | BOOLEAN | NOT NULL, DEFAULT FALSE |
| created_at | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() |
