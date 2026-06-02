# NOTIF-02: Reject Notification Creation When Message Field is Missing or Invalid

## Story
**NOTIF-02**: Reject notification creation when message field is missing or invalid.

**GHERKIN**:
- Scenario: Reject creation when message is missing
  - Given a JSON body with no "message" field and "priority" set to "low"
  - When the client sends a POST request to "/api/notify"
  - Then the system responds with HTTP 400
  - And the response body contains an error indicating "message" is required

- Scenario: Reject creation when message is empty
  - Given a JSON body with "message" set to "" and "priority" set to "medium"
  - When the client sends a POST request to "/api/notify"
  - Then the system responds with HTTP 400
  - And the response body contains a validation error for "message"

## Domain Event
- **Event**: `notifications.NotificationCreated`
- **Payload**: `{ notificationId, priority, title, message, sourceEventType, sourceEventId, targetRoute, timestamp }`
- **Owned by**: Notifications Bounded Context
- **Consumers**: Notification store, Audit.Logging, Analytics.Tracking

## Database Changes

### Migration: `002_notif-02_message_check_constraint`
- **Up** (`002_notif-02_message_check_constraint.up.sql`):
  1. Adds `message` column (`TEXT`) to the `notifications` table (nullable initially)
  2. Backfills existing rows from `body` (or `title` as fallback) where `message IS NULL`
  3. Adds CHECK constraint `ck_notifications_message_not_empty`
     - `message IS NOT NULL AND message != ''`

- **Down** (`002_notif-02_message_check_constraint.down.sql`):
  1. Drops CHECK constraint `ck_notifications_message_not_empty`
  2. Drops the `message` column

### Seed Data: `002_notif-01_seed.sql`
- Provides sample notifications with valid messages for development/testing

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

## Validation Logic
- The CHECK constraint enforces at the database level that:
  - `message` cannot be `NULL`
  - `message` cannot be an empty string `''`
- This provides a hard database-level safeguard alongside application-level validation
- Application-layer validation should also reject missing/empty `message` prior to DB insert for better UX

## Related Files
- `docs/migrations/002_notif-02_message_check_constraint.up.sql`
- `docs/migrations/002_notif-02_message_check_constraint.down.sql`
- `docs/database/seeds/002_notif-01_seed.sql`


# NOTIF-02: Reject Request with Missing Required Fields

## Story
As a system consumer, when I submit a notification request without required fields (`message` or `priority`), I expect a 400 Bad Request response with a clear error message, and no record should be inserted into PostgreSQL.

## Scenarios
1. **Missing "message" field** - Request with `priority="low"` but no `message` → 400 + error indicating `message` is required
2. **Missing "priority" field** - Request with `message="Test"` but no `priority` → 400 + error indicating `priority` is required
3. **Both fields missing** - Request with no fields → 400 + error mentioning both missing fields

## Database Changes

### Migration: `003_notif-02_missing_fields`

**UP:**
1. Clean up existing NULL data:
   - `message` NULL → `''` (empty string)
   - `priority` NULL → `'low'`
2. Add `NOT NULL` constraints on `message` and `priority` columns
3. Add `CHECK` constraint `chk_notifications_priority` restricting valid values to: `'low'`, `'medium'`, `'high'`, `'critical'`
4. Verification block to confirm constraints are applied

**DOWN:**
1. Drop `CHECK` constraint `chk_notifications_priority`
2. Drop `NOT NULL` constraints on `message` and `priority`

### Application Layer Validation
The database constraints serve as **defense-in-depth**. The application layer should also validate:
- `message` must be present and non-empty (trimmed)
- `priority` must be present and one of: `low`, `medium`, `high`, `critical`
- Return HTTP 400 with machine-readable JSON error body

### Files Created
| File | Purpose |
|------|---------|
| `migrations/003_notif-02_missing_fields.up.sql` | Apply NOT NULL + CHECK constraints |
| `migrations/003_notif-02_missing_fields.down.sql` | Revert constraints |
| `seeds/003_notif-02_missing_fields_seed.sql` | Sample notification data |
| `redis/notifications_cache.conf` | Redis cache config for notifications |
