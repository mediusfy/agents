-- Migration: ENTITYMGMT-10_000_outbox_relay.down.sql
-- Story: ENTITYMGMT-10 — Rollback outbox relay enhancements
-- Bounded Context: Entity Management
--
-- Reverses ENTITYMGMT-10_000_outbox_relay.up.sql
--
-- Ordered rollback:
--   1. Drop relay query/management functions
--   2. Drop lifecycle event functions
--   3. Drop relay helper functions
--   4. Drop enhanced indexes
--   5. Drop added columns from outbox_events
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. Drop relay management functions (no inter-dependencies)
-- ============================================================================
DROP FUNCTION IF EXISTS replay_failed_outbox_event(TEXT);
DROP FUNCTION IF EXISTS list_failed_outbox_events(INTEGER, INTEGER);
DROP FUNCTION IF EXISTS get_outbox_event_by_id(TEXT);
DROP FUNCTION IF EXISTS reset_stalled_outbox_events(INTEGER);
DROP FUNCTION IF EXISTS count_stalled_outbox_events(INTEGER);
DROP FUNCTION IF EXISTS count_pending_outbox_events();

-- ============================================================================
-- 2. Drop lifecycle event functions (no inter-dependencies)
-- ============================================================================
DROP FUNCTION IF EXISTS enqueue_outbox_event_failed(TEXT, TEXT, TEXT, INTEGER, TEXT, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS enqueue_outbox_event_published(TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ, BIGINT);

-- ============================================================================
-- 3. Drop relay helper functions (no inter-dependencies)
-- ============================================================================
DROP FUNCTION IF EXISTS get_outbox_latency_ms(TEXT);
DROP FUNCTION IF EXISTS mark_outbox_retry(TEXT, TEXT);
DROP FUNCTION IF EXISTS mark_outbox_failed(TEXT, TEXT);
DROP FUNCTION IF EXISTS mark_outbox_published(TEXT, TEXT);
DROP FUNCTION IF EXISTS fetch_pending_outbox_events(INTEGER);

-- ============================================================================
-- 4. Drop enhanced indexes added by this migration
-- ============================================================================
DROP INDEX IF EXISTS idx_outbox_aggregate_type;
DROP INDEX IF EXISTS idx_outbox_published_subject;
DROP INDEX IF EXISTS idx_outbox_published_at;
DROP INDEX IF EXISTS idx_outbox_stalled_events;

-- Note: The following indexes were recreated in this migration but existed
-- previously with the same name from ENTITYMGMT-01. We DO NOT drop them
-- here to preserve original index coverage.
--   - idx_outbox_pending_events (was recreated)
--   - idx_outbox_failed (was recreated)
-- These indexes pre-existed and remain intact for backward compatibility.

-- ============================================================================
-- 5. Drop added columns from outbox_events
-- ============================================================================
ALTER TABLE outbox_events
    DROP COLUMN IF EXISTS max_retries,
    DROP COLUMN IF EXISTS processed_at,
    DROP COLUMN IF EXISTS nats_subject,
    DROP COLUMN IF EXISTS published_at;

COMMIT;
