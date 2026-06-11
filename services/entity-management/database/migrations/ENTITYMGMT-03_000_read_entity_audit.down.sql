-- Migration: ENTITYMGMT-03_000_read_entity_audit.down.sql
-- Story: ENTITYMGMT-03 — Rollback read entity audit trail
-- Bounded Context: Entity Management
--
-- Reverses ENTITYMGMT-03_000_read_entity_audit.up.sql
--
-- Ordered rollback:
--   1. Drop functions (in reverse dependency order)
--   2. Drop indexes
--   3. Drop table
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. Drop functions (in reverse dependency order)
-- ============================================================================

-- Observability/metrics functions
DROP FUNCTION IF EXISTS get_cross_region_read_summary(TEXT);
DROP FUNCTION IF EXISTS get_read_latency_percentiles(TEXT, UUID, VARCHAR, VARCHAR);

-- Audit trail query functions
DROP FUNCTION IF EXISTS get_read_audit_trail_by_origin(VARCHAR, VARCHAR, INTEGER, INTEGER);
DROP FUNCTION IF EXISTS get_read_audit_trail(VARCHAR, INTEGER, INTEGER);

-- Core atomic function (highest dependency — calls all others)
DROP FUNCTION IF EXISTS get_entity_by_id_with_audit(VARCHAR, VARCHAR, VARCHAR, VARCHAR);

-- Event outbox enqueue function
DROP FUNCTION IF EXISTS enqueue_entity_read_event(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR);

-- Audit log recording function
DROP FUNCTION IF EXISTS log_entity_read(VARCHAR, VARCHAR, VARCHAR, BOOLEAN, VARCHAR, VARCHAR, entity_status, UUID, VARCHAR, INTEGER);

-- TTL cleanup function
DROP FUNCTION IF EXISTS prune_expired_read_audit_logs(INTEGER);

-- ============================================================================
-- 2. Drop indexes (explicit cleanup for idempotency)
-- ============================================================================
DROP INDEX IF EXISTS idx_read_audit_region_outcome;
DROP INDEX IF EXISTS idx_read_audit_read_at;
DROP INDEX IF EXISTS idx_read_audit_request_origin;
DROP INDEX IF EXISTS idx_read_audit_read_by;
DROP INDEX IF EXISTS idx_read_audit_schema_id;
DROP INDEX IF EXISTS idx_read_audit_region;
DROP INDEX IF EXISTS idx_read_audit_deleted;
DROP INDEX IF EXISTS idx_read_audit_outcome;
DROP INDEX IF EXISTS idx_read_audit_entity_id_read_at;

-- ============================================================================
-- 3. Drop table
-- ============================================================================
DROP TABLE IF EXISTS entity_read_audit_log CASCADE;

-- ============================================================================
-- NOTE: The following are NOT dropped by this migration because they are
-- owned by ENTITYMGMT-01 or ENTITYMGMT-02:
--   - update_modified_column() function  (ENTITYMGMT-01)
--   - outbox_events table                (ENTITYMGMT-01)
--   - entities table                     (ENTITYMGMT-02)
--   - get_entity_by_id() function        (ENTITYMGMT-02)
--   - entity_status ENUM                 (ENTITYMGMT-02)
-- ============================================================================

COMMIT;
