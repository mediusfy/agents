-- Migration: ENTITYMGMT-07_000_restore_entity_refinement.down.sql
-- Story: ENTITYMGMT-07 — Rollback restore refinement changes
-- Bounded Context: Entity Management
--
-- Reverses ENTITYMGMT-07_000_restore_entity_refinement.up.sql
--
-- Rollback strategy:
--   Reverts all functions to their ENTITYMGMT-05 baseline state:
--   1. Drop new functions added by this migration (verify_*, validate_*, get_*, row_to_entity_restore_json)
--   2. Restore ENTITYMGMT-05 version of restore_entity()
--   3. Restore ENTITYMGMT-05 version of enqueue_entity_restored_event()
--   4. Restore ENTITYMGMT-05 version of restore_entity_with_outbox()
--   5. Drop indexes added by this migration
--
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. Drop new functions added by ENTITYMGMT-07 only
-- ============================================================================

-- Diagnostic function (added by this migration)
DROP FUNCTION IF EXISTS verify_entity_visible_after_restore(UUID, UUID);

-- Pre-restore validation function (added by this migration)
DROP FUNCTION IF EXISTS validate_entity_restorable(UUID);

-- Restorable entity retrieval function (added by this migration)
DROP FUNCTION IF EXISTS get_restorable_entity(UUID);

-- Extended helper with previous_deleted_at (added by this migration)
DROP FUNCTION IF EXISTS row_to_entity_restore_json(entities, TIMESTAMPTZ);

-- ============================================================================
-- 2. Drop the refined ENTITYMGMT-07 versions of existing functions
-- ============================================================================

-- Combined restore+outbox function (refined by this migration)
DROP FUNCTION IF EXISTS restore_entity_with_outbox(UUID, VARCHAR);

-- Outbox event enqueue function for restore (refined by this migration)
DROP FUNCTION IF EXISTS enqueue_entity_restored_event(UUID, VARCHAR, VARCHAR, TIMESTAMPTZ, VARCHAR);

-- Atomic restore function (refined by this migration)
DROP FUNCTION IF EXISTS restore_entity(UUID);

-- ============================================================================
-- 3. Restore the ENTITYMGMT-05 baseline versions
--
-- These functions are reconstructed exactly as they were in
-- ENTITYMGMT-05_000_soft_delete_restore.up.sql.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 3a. Restore ENTITYMGMT-05 version of row_to_entity_json()
-- (This function existed in ENTITYMGMT-05 and is needed by the restored functions)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION row_to_entity_json(
    p_entity_id UUID
)
RETURNS JSONB AS $$
DECLARE
    v_entity entities%ROWTYPE;
BEGIN
    SELECT * INTO v_entity
    FROM entities
    WHERE id = p_entity_id;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    RETURN jsonb_build_object(
        'id',                  v_entity.id::TEXT,
        'schema_id',           v_entity.schema_id::TEXT,
        'schema_version',      v_entity.schema_version,
        'name',                v_entity.name,
        'type',                v_entity.type,
        'region',              v_entity.region,
        'data_residency_zone', v_entity.data_residency_zone,
        'status',              v_entity.status,
        'version',             v_entity.version,
        'attributes',          v_entity.attributes,
        'metadata',            v_entity.metadata,
        'created_at',          v_entity.created_at,
        'updated_at',          v_entity.updated_at,
        'deleted_at',          v_entity.deleted_at
    );
END;
$$ LANGUAGE plpgsql STABLE;

-- ---------------------------------------------------------------------------
-- 3b. Restore ENTITYMGMT-05 version of restore_entity()
-- Original signature: restore_entity(p_entity_id UUID)
-- Original returns: TABLE(success BOOLEAN, entity_json JSONB, error_code TEXT, error_message TEXT)
-- NOTE: This version does NOT capture or return previous_deleted_at.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION restore_entity(
    p_entity_id UUID
)
RETURNS TABLE(
    success       BOOLEAN,
    entity_json   JSONB,
    error_code    TEXT,
    error_message TEXT
) AS $$
DECLARE
    v_entity    entities%ROWTYPE;
    v_now       TIMESTAMPTZ;
BEGIN
    v_now := NOW();

    SELECT * INTO v_entity
    FROM entities
    WHERE id = p_entity_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT
            FALSE                                   AS success,
            NULL::JSONB                             AS entity_json,
            'ERR_ENTITY_NOT_FOUND'                  AS error_code,
            format('Entity with ID %s not found', p_entity_id::TEXT) AS error_message;
        RETURN;
    END IF;

    IF v_entity.deleted_at IS NULL THEN
        RETURN QUERY SELECT
            FALSE                                   AS success,
            NULL::JSONB                             AS entity_json,
            'ERR_NOT_DELETED'                       AS error_code,
            format('Entity %s (%s) is not soft-deleted and cannot be restored. '
                   || 'Only soft-deleted entities can be restored.',
                   v_entity.name,
                   v_entity.id)                     AS error_message;
        RETURN;
    END IF;

    UPDATE entities
    SET
        status     = 'active'::entity_status,
        deleted_at = NULL,
        version    = version + 1,
        updated_at = v_now
    WHERE id = p_entity_id;

    RETURN QUERY SELECT
        TRUE                        AS success,
        row_to_entity_json(p_entity_id) AS entity_json,
        NULL::TEXT                  AS error_code,
        NULL::TEXT                  AS error_message;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- 3c. Restore ENTITYMGMT-05 version of enqueue_entity_restored_event()
-- Original signature with p_restored_at parameter
-- Original payload includes restored_at, NOT previous_deleted_at
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enqueue_entity_restored_event(
    p_entity_id        UUID,
    p_entity_name      VARCHAR(512),
    p_region           VARCHAR(64),
    p_restored_at      TIMESTAMPTZ,
    p_previous_status  VARCHAR(32) DEFAULT 'deleted',
    p_new_status       VARCHAR(32) DEFAULT 'active',
    p_restored_by      VARCHAR(255) DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_event_id    UUID;
    v_occurred_at TIMESTAMPTZ;
BEGIN
    v_event_id    := gen_random_uuid();
    v_occurred_at := NOW();

    INSERT INTO outbox_events (
        id,
        event_id,
        aggregate_id,
        aggregate_type,
        event_type,
        source,
        subject,
        payload,
        status,
        retry_count,
        last_error,
        created_at
    ) VALUES (
        gen_random_uuid()::TEXT,
        v_event_id::TEXT,
        p_entity_id::TEXT,
        'entity',
        'entitymanagement.entity.restored',
        '/entity-manager',
        'entity/' || p_entity_id::TEXT,
        jsonb_build_object(
            'event_id',         v_event_id::TEXT,
            'entity_id',        p_entity_id::TEXT,
            'entity_name',      p_entity_name,
            'region',           p_region,
            'restored_at',      p_restored_at,
            'previous_status',  p_previous_status,
            'new_status',       p_new_status,
            'restored_by',      p_restored_by,
            'occurred_at',      v_occurred_at
        ),
        'pending',
        0,
        NULL,
        v_occurred_at
    );

    RETURN v_event_id;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- 3d. Restore ENTITYMGMT-05 version of restore_entity_with_outbox()
-- Original signature and return type
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION restore_entity_with_outbox(
    p_entity_id   UUID,
    p_restored_by VARCHAR(255) DEFAULT NULL
)
RETURNS TABLE(
    success       BOOLEAN,
    entity_json   JSONB,
    event_id      UUID,
    error_code    TEXT,
    error_message TEXT
) AS $$
DECLARE
    v_result      RECORD;
    v_entity_name VARCHAR(512);
    v_region      VARCHAR(64);
    v_restored_at TIMESTAMPTZ;
    v_event_id    UUID;
BEGIN
    SELECT * INTO v_result
    FROM restore_entity(p_entity_id := p_entity_id);

    IF NOT v_result.success THEN
        RETURN QUERY SELECT
            v_result.success,
            v_result.entity_json,
            NULL::UUID     AS event_id,
            v_result.error_code,
            v_result.error_message;
        RETURN;
    END IF;

    v_entity_name := v_result.entity_json ->> 'name';
    v_region      := v_result.entity_json ->> 'region';
    v_restored_at := NOW();

    v_event_id := enqueue_entity_restored_event(
        p_entity_id        := p_entity_id,
        p_entity_name      := v_entity_name,
        p_region           := v_region,
        p_restored_at      := v_restored_at,
        p_previous_status  := 'deleted',
        p_new_status       := 'active',
        p_restored_by      := p_restored_by
    );

    RETURN QUERY SELECT
        TRUE                     AS success,
        v_result.entity_json    AS entity_json,
        v_event_id              AS event_id,
        NULL::TEXT              AS error_code,
        NULL::TEXT              AS error_message;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 4. Drop indexes added by ENTITYMGMT-07
-- ============================================================================
DROP INDEX IF EXISTS idx_entities_schema_deleted_recent;
DROP INDEX IF EXISTS idx_entities_region_deleted;
DROP INDEX IF EXISTS idx_entities_name_deleted;
DROP INDEX IF EXISTS idx_entities_restore_lookup;

-- ============================================================================
-- 5. Verify the trigger still allows restore transitions
--
-- The prevent_immutable_field_update trigger from ENTITYMGMT-05 is preserved
-- as-is (we only dropped/restored functions, not the trigger).
-- The trigger already allows the 'deleted' → 'active' transition with
-- deleted_at NULL → timestamp change.
-- ============================================================================

-- ============================================================================
-- 6. Rollback summary
-- ============================================================================
DO $$
BEGIN
    RAISE NOTICE 'ENTITYMGMT-07 migration rolled back successfully.';
    RAISE NOTICE '  - Restored ENTITYMGMT-05 versions of:';
    RAISE NOTICE '      row_to_entity_json()';
    RAISE NOTICE '      restore_entity()';
    RAISE NOTICE '      enqueue_entity_restored_event() (with restored_at)';
    RAISE NOTICE '      restore_entity_with_outbox()';
    RAISE NOTICE '  - Dropped: row_to_entity_restore_json(), validate_entity_restorable(),';
    RAISE NOTICE '             get_restorable_entity(), verify_entity_visible_after_restore()';
    RAISE NOTICE '  - Dropped indexes: schema_deleted_recent, region_deleted, name_deleted, restore_lookup';
    RAISE NOTICE '';
    RAISE NOTICE 'Note: The prevent_immutable_field_update trigger from ENTITYMGMT-05';
    RAISE NOTICE 'still allows restore transitions (deleted → active).';
END;
$$;

COMMIT;
