-- Migration: ENTITYMGMT-11_000_multi_region_data_residency.down.sql
-- Story: ENTITYMGMT-11 — Rollback multi-region data residency changes
-- Bounded Context: Entity Management
--
-- Reverses ENTITYMGMT-11_000_multi_region_data_residency.up.sql
--
-- Reverts:
--   1. Drop diagnostic/query functions added by this migration
--   2. Drop region_routed event function
--   3. Revert enqueue_entity_created_event() to original (without region_routed emission)
--   4. Revert create_entity_with_idempotency() to original
--   5. Drop new indexes added by this migration
--   6. Remove region_updated_at column
--   7. Drop data_residency_zone generated column
--   8. Revert compute_data_residency_zone() to original (group-based: eu-west-1 → 'eu', us-east-1 → 'us')
--   9. Recreate data_residency_zone generated column with old function
--  10. Revert prevent_immutable_field_update to original (without region_updated_at protection)
--  11. Drop region_routed event index
--
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. Drop diagnostic & query functions (added by this migration)
-- ============================================================================
DROP FUNCTION IF EXISTS resolve_entity_zone(UUID);
DROP FUNCTION IF EXISTS count_entities_by_zone();
DROP FUNCTION IF EXISTS list_entities_by_zone(TEXT, entity_status, INTEGER, INTEGER, BOOLEAN);

-- ============================================================================
-- 2. Drop region_routed event function
-- ============================================================================
DROP FUNCTION IF EXISTS enqueue_region_routed_event(UUID, TEXT, TEXT, TEXT);

-- ============================================================================
-- 3. Revert enqueue_entity_created_event() to original (pre-ENTITYMGMT-11)
-- ============================================================================
DROP FUNCTION IF EXISTS enqueue_entity_created_event(UUID, UUID, VARCHAR, VARCHAR, VARCHAR, TEXT, INTEGER, TEXT, JSONB, JSONB);

-- Original function from ENTITYMGMT-02 (without region_routed emission)
CREATE OR REPLACE FUNCTION enqueue_entity_created_event(
    p_entity_id   UUID,
    p_schema_id   UUID,
    p_entity_name VARCHAR(512),
    p_entity_type VARCHAR(255),
    p_region      VARCHAR(64),
    p_zone        TEXT,
    p_version     INTEGER DEFAULT 1,
    p_status      TEXT DEFAULT 'active',
    p_attributes  JSONB DEFAULT '{}',
    p_metadata    JSONB DEFAULT '{}'
)
RETURNS UUID AS $$
DECLARE
    v_event_id    UUID;
    v_outbox_id   TEXT;
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
        'entitymanagement.entity.created',
        '/entity-manager',
        'entity/' || p_entity_id::TEXT,
        jsonb_build_object(
            'event_id',            v_event_id::TEXT,
            'entity_id',           p_entity_id::TEXT,
            'entity_name',         p_entity_name,
            'entity_type',         p_entity_type,
            'region',              p_region,
            'data_residency_zone', p_zone,
            'schema_id',           p_schema_id::TEXT,
            'version',             p_version,
            'status',              p_status,
            'attributes',          p_attributes,
            'metadata',            p_metadata,
            'occurred_at',         v_occurred_at
        ),
        'pending',
        0,
        NULL,
        v_occurred_at
    )
    RETURNING id INTO v_outbox_id;

    RETURN v_outbox_id::UUID;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 4. Revert create_entity_with_idempotency() to original
-- ============================================================================
DROP FUNCTION IF EXISTS create_entity_with_idempotency(UUID, INTEGER, VARCHAR, VARCHAR, VARCHAR, JSONB, JSONB, TEXT, INTEGER);

-- Original function from ENTITYMGMT-02 (without region_updated_at)
CREATE OR REPLACE FUNCTION create_entity_with_idempotency(
    p_schema_id       UUID,
    p_schema_version  INTEGER DEFAULT 1,
    p_name            VARCHAR(512),
    p_type            VARCHAR(255),
    p_region          VARCHAR(64),
    p_attributes      JSONB DEFAULT '{}',
    p_metadata        JSONB DEFAULT '{}',
    p_idempotency_key TEXT DEFAULT NULL,
    p_ttl_days        INTEGER DEFAULT 7
)
RETURNS TABLE(
    out_entity_id   UUID,
    out_version     INTEGER,
    out_status      TEXT,
    out_event_id    UUID,
    out_is_new      BOOLEAN,
    out_created_at  TIMESTAMPTZ
) AS $$
DECLARE
    v_existing_entity_id UUID;
    v_entity_id          UUID;
    v_entity_version     INTEGER;
    v_entity_status      TEXT;
    v_entity_created_at  TIMESTAMPTZ;
    v_zone               TEXT;
    v_event_id           UUID;
BEGIN
    IF p_idempotency_key IS NOT NULL THEN
        SELECT e.id INTO v_existing_entity_id
        FROM entities e
        INNER JOIN request_idempotency ri
            ON ri.entity_id = e.id
        WHERE ri.request_key = p_idempotency_key
          AND ri.expires_at > NOW();

        IF FOUND THEN
            RETURN QUERY
            SELECT
                e.id               AS out_entity_id,
                e.version          AS out_version,
                e.status::TEXT     AS out_status,
                NULL::UUID         AS out_event_id,
                FALSE              AS out_is_new,
                e.created_at       AS out_created_at
            FROM entities e
            WHERE e.id = v_existing_entity_id;
            RETURN;
        END IF;
    END IF;

    v_zone := compute_data_residency_zone(p_region);

    INSERT INTO entities (
        id, schema_id, schema_version, name, type, region,
        status, version, attributes, metadata, created_at, updated_at
    ) VALUES (
        gen_random_uuid(),
        p_schema_id,
        p_schema_version,
        p_name,
        p_type,
        p_region,
        'active',
        1,
        p_attributes,
        p_metadata,
        NOW(),
        NOW()
    )
    RETURNING id, version, status::TEXT, created_at
    INTO v_entity_id, v_entity_version, v_entity_status, v_entity_created_at;

    v_event_id := enqueue_entity_created_event(
        p_entity_id   := v_entity_id,
        p_schema_id   := p_schema_id,
        p_entity_name := p_name,
        p_entity_type := p_type,
        p_region      := p_region,
        p_zone        := v_zone,
        p_version     := v_entity_version,
        p_status      := v_entity_status,
        p_attributes  := p_attributes,
        p_metadata    := p_metadata
    );

    IF p_idempotency_key IS NOT NULL THEN
        PERFORM save_idempotency_key(
            p_request_key := p_idempotency_key,
            p_entity_id   := v_entity_id,
            p_ttl_days    := p_ttl_days
        );
    END IF;

    RETURN QUERY
    SELECT
        v_entity_id         AS out_entity_id,
        v_entity_version    AS out_version,
        v_entity_status     AS out_status,
        v_event_id          AS out_event_id,
        TRUE                AS out_is_new,
        v_entity_created_at AS out_created_at;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 5. Drop indexes added by this migration
-- ============================================================================
DROP INDEX IF EXISTS idx_entities_zone_region_status;
DROP INDEX IF EXISTS idx_entities_zone_created_at;
DROP INDEX IF EXISTS idx_entities_region_zone_updated;
DROP INDEX IF EXISTS idx_entities_known_zones;
DROP INDEX IF EXISTS idx_entities_region_updated_at;
DROP INDEX IF EXISTS idx_entities_schema_zone;
DROP INDEX IF EXISTS idx_outbox_region_routed;

-- ============================================================================
-- 6. Remove region_updated_at column
-- ============================================================================
ALTER TABLE entities
    DROP COLUMN IF EXISTS region_updated_at;

-- ============================================================================
-- 7. Drop data_residency_zone generated column
-- ============================================================================
ALTER TABLE entities
    DROP COLUMN IF EXISTS data_residency_zone;

-- ============================================================================
-- 8. Revert compute_data_residency_zone() to original group-based mapping
-- ============================================================================
DROP FUNCTION IF EXISTS compute_data_residency_zone(TEXT) CASCADE;

CREATE OR REPLACE FUNCTION compute_data_residency_zone(p_region TEXT)
RETURNS TEXT AS $$
BEGIN
    RETURN CASE
        WHEN p_region IN ('us-east-1', 'us-east-2', 'us-west-1', 'us-west-2') THEN 'us'
        WHEN p_region IN ('eu-west-1', 'eu-west-2', 'eu-west-3', 'eu-central-1', 'eu-north-1') THEN 'eu'
        WHEN p_region IN ('ap-southeast-1', 'ap-southeast-2', 'ap-southeast-3') THEN 'ap-southeast'
        WHEN p_region IN ('ap-northeast-1', 'ap-northeast-2', 'ap-northeast-3') THEN 'ap-northeast'
        WHEN p_region IN ('sa-east-1') THEN 'sa'
        WHEN p_region IN ('me-south-1', 'af-south-1') THEN 'me-af'
        WHEN p_region IN ('ca-central-1') THEN 'ca'
        ELSE 'other'
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ============================================================================
-- 9. Recreate data_residency_zone generated column with old function
-- ============================================================================
ALTER TABLE entities
    ADD COLUMN data_residency_zone TEXT
    GENERATED ALWAYS AS (compute_data_residency_zone(region)) STORED;

-- ============================================================================
-- 10. Revert prevent_immutable_field_update to original (without region_updated_at)
-- ============================================================================
DROP TRIGGER IF EXISTS prevent_immutable_field_update ON entities;

CREATE OR REPLACE FUNCTION prevent_immutable_field_update()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.region IS DISTINCT FROM NEW.region THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: region cannot be changed after creation'
            USING HINT = 'The region field is immutable after creation. Data residency zone is derived from region.';
    END IF;

    IF OLD.id IS DISTINCT FROM NEW.id THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: id cannot be changed after creation'
            USING HINT = 'The id field is immutable after creation.';
    END IF;

    IF OLD.data_residency_zone IS DISTINCT FROM NEW.data_residency_zone THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: data_residency_zone is a generated column and cannot be changed'
            USING HINT = 'Data residency zone is derived from the region field and is immutable.';
    END IF;

    IF OLD.type IS DISTINCT FROM NEW.type THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: type cannot be changed after creation'
            USING HINT = 'The type field is immutable after creation.';
    END IF;

    IF OLD.schema_id IS DISTINCT FROM NEW.schema_id THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: schema_id cannot be changed after creation'
            USING HINT = 'The schema_id field is immutable after creation.';
    END IF;

    IF OLD.created_at IS DISTINCT FROM NEW.created_at THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: created_at cannot be changed after creation'
            USING HINT = 'The created_at field is immutable after creation.';
    END IF;

    IF OLD.version IS DISTINCT FROM NEW.version
       AND NEW.version != OLD.version + 1 THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: version cannot be set directly; use optimistic lock mechanism'
            USING HINT = 'The version field is auto-managed by the optimistic concurrency control system.';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER prevent_immutable_field_update
    BEFORE UPDATE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION prevent_immutable_field_update();

-- ============================================================================
-- 11. Notification for dependent services
-- ============================================================================
DO $$
BEGIN
    RAISE NOTICE 'ENTITYMGMT-11 DOWN: Reverted to original group-based zone mapping.';
    RAISE NOTICE '  Restored: eu-west-1 → eu, us-east-1 → us';
    RAISE NOTICE '  Removed: region_updated_at column, region_routed event';
    RAISE NOTICE '  Removed: diagnostic functions (resolve_entity_zone, count_entities_by_zone, list_entities_by_zone)';
END $$;

COMMIT;
