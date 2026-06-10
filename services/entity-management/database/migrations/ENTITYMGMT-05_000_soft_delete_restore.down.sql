-- Migration: ENTITYMGMT-05_000_soft_delete_restore.down.sql
-- Story: ENTITYMGMT-05 — Rollback soft-delete and restore support
-- Bounded Context: Entity Management
--
-- Reverses ENTITYMGMT-05_000_soft_delete_restore.up.sql
--
-- Ordered rollback:
--   1. Drop triggers (recreated in this migration — revert to ENTITYMGMT-04 version)
--   2. Drop functions created by this migration
--   3. Drop indexes added by this migration
--   4. Restore the original prevent_immutable_field_update trigger (ENTITYMGMT-04)
--
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. Drop the updated trigger (replaced in this migration)
-- ============================================================================
DROP TRIGGER IF EXISTS prevent_immutable_field_update ON entities;

-- ============================================================================
-- 2. Drop functions (in reverse dependency order)
-- ============================================================================

-- Combined restore+outbox function
DROP FUNCTION IF EXISTS restore_entity_with_outbox(UUID, VARCHAR);

-- Outbox event enqueue function for restore
DROP FUNCTION IF EXISTS enqueue_entity_restored_event(UUID, VARCHAR, VARCHAR, TIMESTAMPTZ, VARCHAR, VARCHAR, VARCHAR);

-- Atomic restore function
DROP FUNCTION IF EXISTS restore_entity(UUID);

-- Combined soft-delete+outbox function
DROP FUNCTION IF EXISTS soft_delete_entity_with_outbox(UUID, VARCHAR);

-- Outbox event enqueue function for soft-delete
DROP FUNCTION IF EXISTS enqueue_entity_soft_deleted_event(UUID, VARCHAR, VARCHAR, TIMESTAMPTZ, VARCHAR, VARCHAR);

-- Atomic soft-delete function
DROP FUNCTION IF EXISTS soft_delete_entity(UUID);

-- Helper: row_to_entity_json
DROP FUNCTION IF EXISTS row_to_entity_json(UUID);

-- ============================================================================
-- 3. Drop indexes added by this migration
-- ============================================================================
DROP INDEX IF EXISTS idx_entities_deleted_at;
DROP INDEX IF EXISTS idx_entities_deleted_at_retention;
DROP INDEX IF EXISTS idx_entities_schema_active;
DROP INDEX IF EXISTS idx_entities_schema_status_active;
DROP INDEX IF EXISTS idx_entities_region_active;
DROP INDEX IF EXISTS idx_entities_deleted_at_recent;
DROP INDEX IF EXISTS idx_entities_restorable;
DROP INDEX IF EXISTS idx_entities_non_deleted;
DROP INDEX IF EXISTS idx_outbox_lifecycle_events;

-- ============================================================================
-- 4. Restore the original ENTITYMGMT-04 prevent_immutable_field_update trigger
--    (without the soft-delete/restore exemption)
-- ============================================================================
CREATE OR REPLACE FUNCTION prevent_immutable_field_update()
RETURNS TRIGGER AS $$
BEGIN
    -- Gherkin SCENARIO 3: region cannot be changed after creation
    IF OLD.region IS DISTINCT FROM NEW.region THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: region cannot be changed after creation'
            USING HINT = 'The region field is immutable after creation. Data residency zone is derived from region.';
    END IF;

    -- id cannot be changed after creation
    IF OLD.id IS DISTINCT FROM NEW.id THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: id cannot be changed after creation'
            USING HINT = 'The id field is immutable after creation.';
    END IF;

    -- data_residency_zone is a generated column; should never be updated directly
    IF OLD.data_residency_zone IS DISTINCT FROM NEW.data_residency_zone THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: data_residency_zone is a generated column and cannot be changed'
            USING HINT = 'Data residency zone is derived from the region field and is immutable.';
    END IF;

    -- type cannot be changed after creation
    IF OLD.type IS DISTINCT FROM NEW.type THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: type cannot be changed after creation'
            USING HINT = 'The type field is immutable after creation.';
    END IF;

    -- schema_id cannot be changed after creation
    IF OLD.schema_id IS DISTINCT FROM NEW.schema_id THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: schema_id cannot be changed after creation'
            USING HINT = 'The schema_id field is immutable after creation.';
    END IF;

    -- created_at cannot be changed after creation
    IF OLD.created_at IS DISTINCT FROM NEW.created_at THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: created_at cannot be changed after creation'
            USING HINT = 'The created_at field is immutable after creation.';
    END IF;

    -- version is managed by the optimistic lock mechanism.
    IF OLD.version IS DISTINCT FROM NEW.version
       AND NEW.version != OLD.version + 1 THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: version cannot be set directly; use optimistic lock mechanism'
            USING HINT = 'The version field is auto-managed by the optimistic concurrency control system. '
                         'Set the expected version in the WHERE clause, not in SET.';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Recreate the original ENTITYMGMT-04 trigger
CREATE TRIGGER prevent_immutable_field_update
    BEFORE UPDATE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION prevent_immutable_field_update();

COMMIT;
