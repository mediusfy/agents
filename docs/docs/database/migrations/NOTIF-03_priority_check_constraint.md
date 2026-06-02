# NOTIF-03: Reject Notification Creation When Priority Field is Missing or Invalid

## Summary

Add a `priority` column to the `notifications` table with a CHECK constraint enforcing valid values: `'low'`, `'medium'`, `'high'`. The column is also `NOT NULL`, ensuring priority is always provided.

## Migration: 003_notif-03_priority_check_constraint

### Up
1. **Add column** `priority VARCHAR(16)` — nullable initially to allow backfill of existing rows.
2. **Backfill** existing rows with `'medium'` as the safe neutral default.
3. **Set NOT NULL** on the column.
4. **Add CHECK constraint** `ck_notifications_priority` enforcing `priority IN ('low', 'medium', 'high')`.

### Down
1. Drop the CHECK constraint `ck_notifications_priority`.
2. Drop the `priority` column entirely.

## Gherkin Coverage

| Gherkin Scenario | Constraint Layer |
|---|---|
| Missing priority → HTTP 400 | `NOT NULL` on column (DB), validated in API handler |
| Invalid priority "urgent" → HTTP 400 | `CHECK` constraint (DB), validated in API handler |

## Redis Caching

Notifications are cached with key pattern `notify:{id}`. Priority is included in the cached payload so filtering by priority level works at the cache layer.

## Dependencies
- Must be applied **after** `001_initial_schema` (creates `notifications` table)
- Must be applied **after** `002_notif-02_message_check_constraint` (adds `message` column)
