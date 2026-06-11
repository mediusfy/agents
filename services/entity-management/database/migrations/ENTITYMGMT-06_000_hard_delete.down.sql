-- Migration: ENTITYMGMT-06_000_hard_delete.down.sql
-- Story: ENTITYMGMT-06 — Rollback hard-delete support
-- Bounded Context: Entity Management
--
-- Reverses ENTITYMGMT-06_000_hard_delete.up.sql
--
-- Ordered rollback:
--   1. Drop functions created by this migration (in reverse dependency order)
--   2. Drop indexes added by this migration
--
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. Drop functions (in reverse dependency order)
-- ============================================================================

-- Combined hard-delete+outbox function (depends on hard_delete_entity and enqueue_entity_hard_deleted_event)
DROP FUNCTION IF EXISTS hard_delete_entity_with_outbox(UUID);

-- Outbox event enqueue function for entity.hard_deleted
DROP FUNCTION IF EXISTS enqueue_entity_hard_deleted_event(UUID, VARCHAR, VARCHAR, TIMESTAMPTZ, TIMESTAMPTZ);

-- Atomic hard-delete function
DROP FUNCTION IF EXISTS hard_delete_entity(UUID);

-- Utility: prune orphaned idempotency keys
DROP FUNCTION IF EXISTS prune_orphaned_idempotency();

-- ============================================================================
-- 2. Drop indexes added by this migration
-- ============================================================================
DROP INDEX IF EXISTS idx_entities_hard_deletable;
DROP INDEX IF EXISTS idx_entities_deleted_at_bulk_hard_delete;
DROP INDEX IF EXISTS idx_entities_region_deleted;
DROP INDEX IF EXISTS idx_outbox_hard_deleted_events;

COMMIT;
