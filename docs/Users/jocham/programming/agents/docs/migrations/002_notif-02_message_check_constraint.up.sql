

-- ============================================================
-- NOTIF-02: Reject notification creation when message field
--           is missing or invalid (Up Migration)
-- PostgreSQL 16-compatible
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1. Add message column to notifications table
--    (nullable initially to allow backfill of existing rows)
-- ------------------------------------------------------------
ALTER TABLE notifications
    ADD COLUMN message TEXT;

-- ------------------------------------------------------------
-- 2. Backfill existing rows with a meaningful default
--    Uses body if present, otherwise falls back to title
--    (title is guaranteed NOT NULL from the initial schema)
-- ------------------------------------------------------------
UPDATE notifications
SET message = COALESCE(NULLIF(body, ''), title)
WHERE message IS NULL;

-- ------------------------------------------------------------
-- 3. Add CHECK constraint ensuring message is NOT NULL
--    and not an empty string
-- ------------------------------------------------------------
ALTER TABLE notifications
    ADD CONSTRAINT ck_notifications_message_not_empty
    CHECK (message IS NOT NULL AND message != '');

COMMIT;
