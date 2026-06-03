-- Migration: ENTITYMGMT-09_000_cursor_pagination_filtering.down.sql
-- Story: ENTITYMGMT-09 — Rollback cursor-based pagination and multi-field filtering
-- Bounded Context: Entity Management
--
-- Reverses ENTITYMGMT-09_000_cursor_pagination_filtering.up.sql
--
-- Ordered rollback:
--   1. Drop pagination-related outbox event functions
--   2. Drop pagination and filtering functions
--   3. Drop helper functions (encode/decode cursor, build filter)
--   4. Drop indexes added by this migration
--   5. Drop verification function
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. Drop outbox event functions
-- ============================================================================
DROP FUNCTION IF EXISTS enqueue_entities_queried_event(TEXT, INTEGER, TEXT[], BOOLEAN, BOOLEAN, BIGINT, INTEGER);
DROP FUNCTION IF EXISTS enqueue_invalid_cursor_event(TEXT, TEXT, TEXT, TEXT);

-- ============================================================================
-- 2. Drop pagination and filtering functions
-- ============================================================================
DROP FUNCTION IF EXISTS list_entities_cursor_with_meta(TEXT, INTEGER, TEXT, TEXT[], BOOLEAN);
DROP FUNCTION IF EXISTS list_entities_cursor(TEXT, INTEGER, TEXT, TEXT[], BOOLEAN);

-- ============================================================================
-- 3. Drop helper functions
-- ============================================================================
DROP FUNCTION IF EXISTS build_filter_clause(TEXT, TEXT, INTEGER);
DROP FUNCTION IF EXISTS decode_cursor_token(TEXT);
DROP FUNCTION IF EXISTS encode_cursor_token(TIMESTAMPTZ, UUID);

-- ============================================================================
-- 4. Drop indexes added by this migration
-- ============================================================================
DROP INDEX IF EXISTS idx_outbox_pagination_events;
DROP INDEX IF EXISTS idx_entities_schema_zone_filter;
DROP INDEX IF EXISTS idx_entities_schema_created_id_all;
DROP INDEX IF EXISTS idx_entities_attributes_gin;
DROP INDEX IF EXISTS idx_entities_schema_status_region;
DROP INDEX IF EXISTS idx_entities_schema_region_filter;
DROP INDEX IF EXISTS idx_entities_schema_status_filter;
DROP INDEX IF EXISTS idx_entities_schema_created_id_active;
DROP INDEX IF EXISTS idx_entities_schema_created_at;
DROP INDEX IF EXISTS idx_entities_schema_created_id;

-- ============================================================================
-- 5. Drop verification function
-- ============================================================================
DROP FUNCTION IF EXISTS verify_cursor_pagination();

-- ============================================================================
-- 6. Bootstrap: Return rollback summary
-- ============================================================================
DO $$
BEGIN
    RAISE NOTICE 'ENTITYMGMT-09 migration rolled back successfully.';
    RAISE NOTICE '  - Dropped: All pagination functions, helpers, and indexes';
    RAISE NOTICE '  - Preserved: entities table, entity_status ENUM, all prior modifications';
END;
$$;

COMMIT;
