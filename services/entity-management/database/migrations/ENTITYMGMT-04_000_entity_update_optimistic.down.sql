-- Migration: ENTITYMGMT-04_000_entity_update_optimistic.down.sql
-- Story: ENTITYMGMT-04 — Rollback optimistic concurrency update support
-- Bounded Context: Entity Management
--
-- Reverses ENTITYMGMT-04_000_entity_update_optimistic.up.sql
--
-- Ordered rollback:
--   1. Drop triggers (prevent_immutable_field_update on entities)
--   2. Drop functions created by this migration
--   3. Drop indexes added by this migration
--
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. Drop triggers
-- ============================================================================
DROP TRIGGER IF EXISTS prevent_immutable_field_update ON entities;

-- ============================================================================
-- 2. Drop functions (in reverse dependency order)
-- ============================================================================

-- Combined update+outbox function (depends on update_entity_optimistic and enqueue_entity_updated_event)
DROP FUNCTION IF EXISTS update_entity_with_outbox(UUID, INTEGER, VARCHAR, entity_status, JSONB, JSONB, INTEGER);

-- Atomic optimistic update function
DROP FUNCTION IF EXISTS update_entity_optimistic(UUID, INTEGER, VARCHAR, entity_status, JSONB, JSONB, INTEGER);

-- Outbox event enqueue function for entity.updated
DROP FUNCTION IF EXISTS enqueue_entity_updated_event(UUID, VARCHAR, entity_status, VARCHAR, INTEGER, INTEGER, TEXT[], JSONB, JSONB);

-- Immutable field protection trigger function
DROP FUNCTION IF EXISTS prevent_immutable_field_update();

-- Diagnostic and validation functions
DROP FUNCTION IF EXISTS get_entity_by_id_with_version(UUID);
DROP FUNCTION IF EXISTS validate_entity_version(UUID, INTEGER);
DROP FUNCTION IF EXISTS check_entity_staleness(UUID, INTEGER);
DROP FUNCTION IF EXISTS count_entity_updates_since_version(UUID, INTEGER);

-- ============================================================================
-- 3. Drop indexes added by this migration
-- ============================================================================
DROP INDEX IF EXISTS idx_entities_id_version;
DROP INDEX IF EXISTS idx_entities_version_status;
DROP INDEX IF EXISTS idx_entities_updated_at_id;

COMMIT;
