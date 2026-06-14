-- Migration: ENTITYMGMT-08_000_status_lifecycle.down.sql
-- Story: ENTITYMGMT-08 — Rollback status lifecycle enforcement
-- Bounded Context: Entity Management
--
-- Reverses ENTITYMGMT-08_000_status_lifecycle.up.sql
--
-- Rollback strategy:
--   Reverts all functions to their ENTITYMGMT-05/07 baseline state:
--   1. Drop new functions added by this migration
--   2. Restore ENTITYMGMT-05 version of prevent_immutable_field_update trigger
--   3. Restore ENTITYMGMT-04 version of enqueue_entity_updated_event()
--   4. Restore ENTITYMGMT-04 version of update_entity_optimistic()
--   5. Restore ENTITYMGMT-04 version of update_entity_with_outbox()
--   6. Drop indexes added by this migration
--
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. Drop functions added by ENTITYMGMT-08 only
-- ============================================================================

-- Diagnostic/validation function
DROP FUNCTION IF EXISTS verify_status_lifecycle();

-- Dedicated status-only update function
DROP FUNCTION IF EXISTS update_entity_status_with_outbox(UUID, INTEGER, entity_status);

-- Core lifecycle validation function
DROP FUNCTION IF EXISTS validate_status_transition(entity_status, entity_status, BOOLEAN);

-- ============================================================================
-- 2. Drop the updated prevent_immutable_field_update trigger
-- ============================================================================
DROP TRIGGER IF EXISTS prevent_immutable_field_update ON entities;

-- ============================================================================
-- 3. Drop the updated functions (ENTITYMGMT-08 signatures)
-- ============================================================================

-- Updated enqueue function (added p_previous_status parameter)
DROP FUNCTION IF EXISTS enqueue_entity_updated_event(
    UUID, VARCHAR(512), entity_status, VARCHAR(64),
    INTEGER, INTEGER, TEXT[], entity_status, JSONB, JSONB
);

-- Updated update_entity_optimistic (added previous_status/new_status returns)
DROP FUNCTION IF EXISTS update_entity_optimistic(
    UUID, INTEGER, VARCHAR(512), entity_status, JSONB, JSONB, INTEGER
);

-- Updated update_entity_with_outbox (updated internals)
DROP FUNCTION IF EXISTS update_entity_with_outbox(
    UUID, INTEGER, VARCHAR(512), entity_status, JSONB, JSONB, INTEGER
);

-- ============================================================================
-- 4. Restore the ENTITYMGMT-05 prevent_immutable_field_update trigger
--    (allows soft-delete and restore exemptions, but BLOCKS active↔inactive)
-- ============================================================================
CREATE OR REPLACE FUNCTION prevent_immutable_field_update()
RETURNS TRIGGER AS $$
BEGIN
    -- Gherkin SCENARIO 1: Soft-delete transition — ALLOWED
    IF OLD.status IN ('active', 'inactive')
       AND NEW.status = 'deleted'::entity_status
       AND OLD.deleted_at IS NULL
       AND NEW.deleted_at IS NOT NULL THEN
        RETURN NEW;
    END IF;

    -- Restore transition — ALLOWED
    IF OLD.status = 'deleted'::entity_status
       AND NEW.status = 'active'::entity_status
       AND OLD.deleted_at IS NOT NULL
       AND NEW.deleted_at IS NULL THEN
        RETURN NEW;
    END IF;

    -- Immutable: region cannot be changed after creation
    IF OLD.region IS DISTINCT FROM NEW.region THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: region cannot be changed after creation'
            USING HINT = 'The region field is immutable after creation. Data residency zone is derived from region.';
    END IF;

    -- Immutable: id cannot be changed after creation
    IF OLD.id IS DISTINCT FROM NEW.id THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: id cannot be changed after creation'
            USING HINT = 'The id field is immutable after creation.';
    END IF;

    -- Immutable: data_residency_zone is a generated column
    IF OLD.data_residency_zone IS DISTINCT FROM NEW.data_residency_zone THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: data_residency_zone is a generated column and cannot be changed'
            USING HINT = 'Data residency zone is derived from the region field and is immutable.';
    END IF;

    -- Immutable: type cannot be changed after creation
    IF OLD.type IS DISTINCT FROM NEW.type THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: type cannot be changed after creation'
            USING HINT = 'The type field is immutable after creation.';
    END IF;

    -- Immutable: schema_id cannot be changed after creation
    IF OLD.schema_id IS DISTINCT FROM NEW.schema_id THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: schema_id cannot be changed after creation'
            USING HINT = 'The schema_id field is immutable after creation.';
    END IF;

    -- Immutable: created_at cannot be changed after creation
    IF OLD.created_at IS DISTINCT FROM NEW.created_at THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: created_at cannot be changed after creation'
            USING HINT = 'The created_at field is immutable after creation.';
    END IF;

    -- Immutable: version is managed by the optimistic lock mechanism
    IF OLD.version IS DISTINCT FROM NEW.version
       AND NEW.version != OLD.version + 1 THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: version cannot be set directly; use optimistic lock mechanism'
            USING HINT = 'The version field is auto-managed by the optimistic concurrency control system. '
                         'Set the expected version in the WHERE clause, not in SET.';
    END IF;

    -- Immutable: status changes not related to soft-delete or restore
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: status cannot be changed directly. '
                        || 'Use soft-delete (DELETE endpoint) or restore (POST .../restore) '
                        || 'to transition entity lifecycle status.'
            USING HINT = format('Attempted to change status from %s to %s. Only soft-delete '
                                || '(active/inactive → deleted) and restore (deleted → active) '
                                || 'transitions are allowed.',
                                OLD.status, NEW.status);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Recreate the trigger
CREATE TRIGGER prevent_immutable_field_update
    BEFORE UPDATE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION prevent_immutable_field_update();

-- ============================================================================
-- 5. Restore ENTITYMGMT-04 version of enqueue_entity_updated_event()
--    (without p_previous_status parameter, without previous_status/new_status in payload)
-- ============================================================================
CREATE OR REPLACE FUNCTION enqueue_entity_updated_event(
    p_entity_id         UUID,
    p_entity_name       VARCHAR(512),
    p_entity_status     entity_status,
    p_region            VARCHAR(64),
    p_previous_version  INTEGER,
    p_new_version       INTEGER,
    p_changed_fields    TEXT[],
    p_previous_state    JSONB DEFAULT '{}',
    p_new_state         JSONB DEFAULT '{}'
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
        'entitymanagement.entity.updated',
        '/entity-manager',
        'entity/' || p_entity_id::TEXT,
        jsonb_build_object(
            'event_id',          v_event_id::TEXT,
            'entity_id',         p_entity_id::TEXT,
            'entity_name',       p_entity_name,
            'status',            p_entity_status,
            'region',            p_region,
            'previous_version',  p_previous_version,
            'new_version',       p_new_version,
            'changed_fields',    to_jsonb(p_changed_fields),
            'previous_state',    p_previous_state,
            'new_state',         p_new_state,
            'occurred_at',       v_occurred_at
        ),
        'pending',
        0,
        NULL,
        v_occurred_at
    );

    RETURN v_event_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 6. Restore ENTITYMGMT-04 version of update_entity_optimistic()
--    (without previous_status/new_status in return type)
-- ============================================================================
CREATE OR REPLACE FUNCTION update_entity_optimistic(
    p_entity_id         UUID,
    p_expected_version  INTEGER,
    p_name              VARCHAR(512) DEFAULT NULL,
    p_status            entity_status DEFAULT NULL,
    p_attributes        JSONB DEFAULT NULL,
    p_metadata          JSONB DEFAULT NULL,
    p_schema_version    INTEGER DEFAULT NULL
)
RETURNS TABLE(
    success          BOOLEAN,
    entity_json      JSONB,
    previous_version INTEGER,
    new_version      INTEGER,
    changed_fields   TEXT[]
) AS $$
DECLARE
    v_current          entities%ROWTYPE;
    v_new              entities%ROWTYPE;
    v_changed          TEXT[] := '{}';
    v_rows_affected    INTEGER;
BEGIN
    SELECT * INTO v_current
    FROM entities
    WHERE id = p_entity_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT
            FALSE                    AS success,
            NULL::JSONB              AS entity_json,
            p_expected_version       AS previous_version,
            NULL::INTEGER            AS new_version,
            NULL::TEXT[]             AS changed_fields;
        RETURN;
    END IF;

    IF v_current.version != p_expected_version THEN
        RETURN QUERY SELECT
            FALSE                    AS success,
            NULL::JSONB              AS entity_json,
            v_current.version        AS previous_version,
            NULL::INTEGER            AS new_version,
            NULL::TEXT[]             AS changed_fields;
        RETURN;
    END IF;

    UPDATE entities
    SET
        name       = COALESCE(p_name, entities.name),
        status     = COALESCE(p_status, entities.status),
        attributes = CASE
                        WHEN p_attributes IS NULL THEN entities.attributes
                        ELSE entities.attributes || p_attributes
                     END,
        metadata   = CASE
                        WHEN p_metadata IS NULL THEN entities.metadata
                        ELSE entities.metadata || p_metadata
                     END,
        schema_version = COALESCE(p_schema_version, entities.schema_version),
        version    = version + 1,
        updated_at = NOW()
    WHERE id = p_entity_id
      AND version = p_expected_version
    RETURNING * INTO v_new;

    GET DIAGNOSTICS v_rows_affected = ROW_COUNT;

    IF v_rows_affected = 0 THEN
        SELECT version INTO v_current.version
        FROM entities WHERE id = p_entity_id;

        RETURN QUERY SELECT
            FALSE                    AS success,
            NULL::JSONB              AS entity_json,
            v_current.version        AS previous_version,
            NULL::INTEGER            AS new_version,
            NULL::TEXT[]             AS changed_fields;
        RETURN;
    END IF;

    IF v_current.name IS DISTINCT FROM v_new.name THEN
        v_changed := array_append(v_changed, 'name');
    END IF;

    IF v_current.status IS DISTINCT FROM v_new.status THEN
        v_changed := array_append(v_changed, 'status');
    END IF;

    IF v_current.schema_version IS DISTINCT FROM v_new.schema_version THEN
        v_changed := array_append(v_changed, 'schema_version');
    END IF;

    IF v_current.attributes IS DISTINCT FROM v_new.attributes THEN
        DECLARE
            v_key TEXT;
            v_old_val JSONB;
            v_new_val JSONB;
        BEGIN
            FOR v_key, v_new_val IN SELECT * FROM jsonb_each(v_new.attributes)
            LOOP
                v_old_val := v_current.attributes -> v_key;
                IF v_old_val IS DISTINCT FROM v_new_val THEN
                    v_changed := array_append(v_changed, 'attributes.' || v_key);
                END IF;
            END LOOP;
            FOR v_key, v_old_val IN SELECT * FROM jsonb_each(v_current.attributes)
            LOOP
                IF NOT v_new.attributes ? v_key THEN
                    v_changed := array_append(v_changed, 'attributes.' || v_key);
                END IF;
            END LOOP;
        END;
    END IF;

    IF v_current.metadata IS DISTINCT FROM v_new.metadata THEN
        DECLARE
            v_key TEXT;
            v_old_val JSONB;
            v_new_val JSONB;
        BEGIN
            FOR v_key, v_new_val IN SELECT * FROM jsonb_each(v_new.metadata)
            LOOP
                v_old_val := v_current.metadata -> v_key;
                IF v_old_val IS DISTINCT FROM v_new_val THEN
                    v_changed := array_append(v_changed, 'metadata.' || v_key);
                END IF;
            END LOOP;
            FOR v_key, v_old_val IN SELECT * FROM jsonb_each(v_current.metadata)
            LOOP
                IF NOT v_new.metadata ? v_key THEN
                    v_changed := array_append(v_changed, 'metadata.' || v_key);
                END IF;
            END LOOP;
        END;
    END IF;

    v_changed := array_append(v_changed, 'version');

    RETURN QUERY SELECT
        TRUE                    AS success,
        jsonb_build_object(
            'id',                  v_new.id::TEXT,
            'schema_id',           v_new.schema_id::TEXT,
            'schema_version',      v_new.schema_version,
            'name',                v_new.name,
            'type',                v_new.type,
            'region',              v_new.region,
            'data_residency_zone', v_new.data_residency_zone,
            'status',              v_new.status,
            'version',             v_new.version,
            'attributes',          v_new.attributes,
            'metadata',            v_new.metadata,
            'created_at',          v_new.created_at,
            'updated_at',          v_new.updated_at,
            'deleted_at',          v_new.deleted_at
        ) AS entity_json,
        p_expected_version      AS previous_version,
        v_new.version           AS new_version,
        v_changed               AS changed_fields;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 7. Restore ENTITYMGMT-04 version of update_entity_with_outbox()
--    (without previous_status/new_status threading)
-- ============================================================================
CREATE OR REPLACE FUNCTION update_entity_with_outbox(
    p_entity_id         UUID,
    p_expected_version  INTEGER,
    p_name              VARCHAR(512) DEFAULT NULL,
    p_status            entity_status DEFAULT NULL,
    p_attributes        JSONB DEFAULT NULL,
    p_metadata          JSONB DEFAULT NULL,
    p_schema_version    INTEGER DEFAULT NULL
)
RETURNS TABLE(
    success          BOOLEAN,
    entity_json      JSONB,
    previous_version INTEGER,
    new_version      INTEGER,
    changed_fields   TEXT[],
    event_id         UUID,
    error_code       TEXT,
    error_message    TEXT
) AS $$
DECLARE
    v_result         RECORD;
    v_entity_id      UUID;
    v_entity_name    VARCHAR(512);
    v_entity_status  entity_status;
    v_region         VARCHAR(64);
    v_previous_state JSONB;
    v_new_state      JSONB;
    v_event_id       UUID;
    v_exc_message    TEXT;
    v_exc_detail     TEXT;
    v_exc_hint       TEXT;
BEGIN
    BEGIN
        SELECT * INTO v_result
        FROM update_entity_optimistic(
            p_entity_id         := p_entity_id,
            p_expected_version  := p_expected_version,
            p_name              := p_name,
            p_status            := p_status,
            p_attributes        := p_attributes,
            p_metadata          := p_metadata,
            p_schema_version    := p_schema_version
        );
    EXCEPTION
        WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS
                v_exc_message = MESSAGE_TEXT,
                v_exc_detail = PG_EXCEPTION_DETAIL,
                v_exc_hint = PG_EXCEPTION_HINT;

            IF v_exc_message LIKE 'ERR_IMMUTABLE_FIELD:%' THEN
                RETURN QUERY SELECT
                    FALSE                             AS success,
                    NULL::JSONB                       AS entity_json,
                    p_expected_version                AS previous_version,
                    NULL::INTEGER                     AS new_version,
                    NULL::TEXT[]                      AS changed_fields,
                    NULL::UUID                        AS event_id,
                    'IMMUTABLE_FIELD'                 AS error_code,
                    v_exc_message                     AS error_message;
                RETURN;
            END IF;

            RAISE;
    END;

    IF NOT v_result.success THEN
        RETURN QUERY SELECT
            FALSE                             AS success,
            NULL::JSONB                       AS entity_json,
            v_result.previous_version         AS previous_version,
            NULL::INTEGER                     AS new_version,
            NULL::TEXT[]                      AS changed_fields,
            NULL::UUID                        AS event_id,
            'STALE_VERSION'                   AS error_code,
            'Stale version: expected ' || p_expected_version::TEXT ||
            ' but current version is ' || v_result.previous_version::TEXT
                                                AS error_message;
        RETURN;
    END IF;

    v_entity_id     := p_entity_id;
    v_entity_name   := v_result.entity_json ->> 'name';
    v_entity_status := (v_result.entity_json ->> 'status')::entity_status;
    v_region        := v_result.entity_json ->> 'region';

    v_previous_state := jsonb_build_object(
        'name',       COALESCE(p_name, v_result.entity_json ->> 'name'),
        'status',     COALESCE(p_status::TEXT, v_result.entity_json ->> 'status'),
        'version',    p_expected_version
    );

    v_new_state := jsonb_build_object(
        'name',       v_result.entity_json ->> 'name',
        'status',     v_result.entity_json ->> 'status',
        'version',    v_result.new_version
    );

    v_event_id := enqueue_entity_updated_event(
        p_entity_id         := v_entity_id,
        p_entity_name       := v_entity_name,
        p_entity_status     := v_entity_status,
        p_region            := v_region,
        p_previous_version  := p_expected_version,
        p_new_version       := v_result.new_version,
        p_changed_fields    := v_result.changed_fields,
        p_previous_state    := v_previous_state,
        p_new_state         := v_new_state
    );

    RETURN QUERY SELECT
        TRUE                              AS success,
        v_result.entity_json              AS entity_json,
        p_expected_version                AS previous_version,
        v_result.new_version              AS new_version,
        v_result.changed_fields           AS changed_fields,
        v_event_id                        AS event_id,
        NULL::TEXT                        AS error_code,
        NULL::TEXT                        AS error_message;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 8. Drop indexes added by ENTITYMGMT-08
-- ============================================================================
DROP INDEX IF EXISTS idx_entities_status_transition;
DROP INDEX IF EXISTS idx_entities_schema_status_version;
DROP INDEX IF EXISTS idx_entities_status_updated;
DROP INDEX IF EXISTS idx_entities_active_only;
DROP INDEX IF EXISTS idx_entities_inactive_only;

-- ============================================================================
-- 9. Rollback summary
-- ============================================================================
DO $$
BEGIN
    RAISE NOTICE 'ENTITYMGMT-08 migration rolled back successfully.';
    RAISE NOTICE '  - Dropped: validate_status_transition(), update_entity_status_with_outbox(),';
    RAISE NOTICE '             verify_status_lifecycle()';
    RAISE NOTICE '  - Restored ENTITYMGMT-05 prevent_immutable_field_update trigger';
    RAISE NOTICE '    (active↔inactive transitions are NO LONGER allowed)';
    RAISE NOTICE '  - Restored ENTITYMGMT-04 enqueue_entity_updated_event()';
    RAISE NOTICE '    (payload no longer includes previous_status/new_status)';
    RAISE NOTICE '  - Restored ENTITYMGMT-04 update_entity_optimistic()';
    RAISE NOTICE '  - Restored ENTITYMGMT-04 update_entity_with_outbox()';
    RAISE NOTICE '  - Dropped indexes: status_transition, schema_status_version,';
    RAISE NOTICE '                     status_updated, active_only, inactive_only';
    RAISE NOTICE '';
    RAISE NOTICE 'Note: The trigger now BLOCKS active↔inactive transitions.';
    RAISE NOTICE 'Only soft-delete (active/inactive→deleted) and restore (deleted→active)';
    RAISE NOTICE 'transitions are allowed after rollback.';
END;
$$;

COMMIT;
