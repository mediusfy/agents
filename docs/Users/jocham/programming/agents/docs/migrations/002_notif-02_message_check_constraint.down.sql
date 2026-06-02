

-- ============================================================
-- NOTIF-02: Reject notification creation when message field
--           is missing or invalid (Down Migration)
-- PostgreSQL 16-compatible
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1. Drop the CHECK constraint on message
-- ------------------------------------------------------------
ALTER TABLE notifications
    DROP CONSTRAINT IF EXISTS ck_notifications_message_not_empty;

-- ------------------------------------------------------------
-- 2. Remove the message column
-- ------------------------------------------------------------
ALTER TABLE notifications
    DROP COLUMN IF EXISTS message;

COMMIT;
