-- Migration: ENTITYMGMT-11_000_multi_region_data_residency.up.sql
-- Story: ENTITYMGMT-11 — System enforces multi-region data residency (us-east-1, eu-west-1)
-- Bounded Context: Entity Management
--
-- Prerequisites:
--   - ENTITYMGMT-01_000_schema_definition.up.sql
--     (outbox_events table, update_modified_column() function)
--   - ENTITYMGMT-02_000_create_entities.up.sql
--     (entities table, compute_data_residency_zone() function, data_residency_zone generated column)
--   - ENTITYMGMT-04_000_entity_update_optimistic.up.sql
--     (prevent_immutable_field_update trigger, update_entity_with_outbox function)
--
-- ============================================================================
-- Gherkin Scenarios
-- ============================================================================
--
-- SCENARIO 1: Entity creation resolves correct DataResidencyZone
--   Given the system is deployed across us-east-1 and eu-west-1 regions
--   When an entity is created with region="eu-west-1"
--   Then the entity's DataResidencyZone is resolved to "eu-west-1" (via ResolveZone function)
--     And observability spans include the region attribute for latency tracking
--
-- SCENARIO 2: Known region mapping
--   Given region "eu-west-1" maps to DataResidencyZone "eu-west-1"
--     And region "us-east-1" maps to DataResidencyZone "us-east-1"
--   When the ResolveZone function is called
--   Then it correctly maps known regions to their residency zones
--     And unknown regions pass through as-is (default behavior)
--
-- SCENARIO 3: Immutable data_residency_zone field
--   Given an entity's data_residency_zone is set to "eu-west-1"
--   When a user attempts to update the data_residency_zone field via the update endpoint
--   Then ErrImmutableField is returned because "data_residency_zone" is in the ImmutableFields list
--     And no data modification occurs
--
-- ============================================================================
-- Domain Events (transactional outbox, reusing outbox_events from ENTITYMGMT-01)
-- ============================================================================
--
-- entitymanagement.residency.region_routed — Published when an entity is routed to
--   a specific data residency zone. Owned by EntityManagement context.
--
--   Payload:
--     { event_id, entity_id, region, data_residency_zone, routing_decision, occurred_at }
--
--   Consumers:
--     ObservabilityContext — Enrich spans with region attributes for latency tracking
--     RoutingContext — Update regional routing table
--
-- ============================================================================
-- DDL changes in this migration:
--   1. Update compute_data_residency_zone() to map regions ONE-TO-ONE:
--      eu-west-1 → eu-west-1, us-east-1 → us-east-1 (NOT short names 'eu'/'us')
--      Unknown regions pass through as-is
--   2. Recreate the data_residency_zone generated column (recomputes all rows)
--   3. Create enqueue_region_routed_event() outbox function
--   4. Add new indexes for residency-aware query patterns
--   5. Add region_updated_at tracking for observability span enrichment
--   6. Update prevent_immutable_field_update trigger to protect zone via generated column
--
-- ============================================================================

BEGIN;

-- ============================================================================
-- SECTION 1: Rebuild compute_data_residency_zone() with correct mapping
-- ============================================================================
--
-- Gherkin SCENARIO 2 (updated mapping):
--   region "eu-west-1" → DataResidencyZone "eu-west-1"  (previously mapped to "eu")
--   region "us-east-1" → DataResidencyZone "us-east-1"  (previously mapped to "us")
--   unknown regions    → pass through as-is              (unchanged — still default behavior)
--
-- The old function collapsed multiple regions into zone groups (e.g., all eu-* → 'eu').
-- The new function maps each KNOWN region to ITSELF as the residency zone.
-- Unknown regions pass through unchanged, which is important for:
--   - Future region additions without schema changes
--   - Custom/private regions in isolated deployments
--   - Backward compatibility with existing data
-- ============================================================================

-- Step 1a: Drop the generated column that depends on this function
ALTER TABLE entities
    DROP COLUMN IF EXISTS data_residency_zone;

-- Step 1b: Drop the old function with CASCADE to handle any remaining dependencies
DROP FUNCTION IF EXISTS compute_data_residency_zone(TEXT) CASCADE;

-- Step 1c: Create updated function with ONE-TO-ONE region→zone mapping
--
-- Gherkin SCENARIO 2 compliance:
--   "eu-west-1" → "eu-west-1"     (zone = region)
--   "us-east-1" → "us-east-1"     (zone = region)
--   unknown     → "{region}"      (pass-through as-is)
--
-- Additional known regions mapped to themselves for consistency:
--   eu-west-2, eu-west-3, eu-central-1, eu-north-1 → themselves
--   us-east-2, us-west-1, us-west-2 → themselves
--   ap-southeast-1, ap-southeast-2, ap-northeast-1, etc. → themselves
--
-- The function is intentionally IMMUTABLE because:
--   1. The mapping is a static, compile-time decision
--   2. It is used by a GENERATED ALWAYS AS (STORED) column
--   3. It allows the query planner to optimize based on the result
CREATE OR REPLACE FUNCTION compute_data_residency_zone(p_region TEXT)
RETURNS TEXT AS $$
BEGIN
    RETURN CASE
        -- AWS us-east regions → map to themselves (no group collapse)
        WHEN p_region IN ('us-east-1', 'us-east-2') THEN p_region
        -- AWS us-west regions → map to themselves
        WHEN p_region IN ('us-west-1', 'us-west-2') THEN p_region
        -- AWS eu-west regions → map to themselves (Gherkin: eu-west-1 → eu-west-1)
        WHEN p_region IN ('eu-west-1', 'eu-west-2', 'eu-west-3') THEN p_region
        -- AWS eu-central / eu-north → map to themselves
        WHEN p_region IN ('eu-central-1', 'eu-north-1') THEN p_region
        -- AWS ap-southeast → map to themselves
        WHEN p_region IN ('ap-southeast-1', 'ap-southeast-2', 'ap-southeast-3') THEN p_region
        -- AWS ap-northeast → map to themselves
        WHEN p_region IN ('ap-northeast-1', 'ap-northeast-2', 'ap-northeast-3') THEN p_region
        -- AWS sa-east-1 → map to itself
        WHEN p_region = 'sa-east-1' THEN p_region
        -- AWS me-south-1, af-south-1 → map to themselves
        WHEN p_region IN ('me-south-1', 'af-south-1') THEN p_region
        -- AWS ca-central-1 → map to itself
        WHEN p_region = 'ca-central-1' THEN p_region
        -- Gherkin SCENARIO 2: "Unknown regions pass through as-is (default behavior)"
        ELSE p_region
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Verify the function returns correct mappings
-- These DO blocks are silent assertions for the migration log.
DO $$
BEGIN
    -- Gherkin SCENARIO 2: known regions
    ASSERT compute_data_residency_zone('eu-west-1') = 'eu-west-1',
        'expected eu-west-1 → eu-west-1';
    ASSERT compute_data_residency_zone('us-east-1') = 'us-east-1',
        'expected us-east-1 → us-east-1';

    -- Gherkin SCENARIO 2: unknown regions pass through
    ASSERT compute_data_residency_zone('unknown-region-1') = 'unknown-region-1',
        'expected unknown → pass-through';
    ASSERT compute_data_residency_zone('local-dev') = 'local-dev',
        'expected local-dev → pass-through';
END $$;

-- ============================================================================
-- SECTION 2: Recreate data_residency_zone generated column
-- ============================================================================
--
-- Gherkin SCENARIO 1:
--   "When an entity is created with region='eu-west-1'
--    Then the entity's DataResidencyZone is resolved to 'eu-west-1'"
--
-- The GENERATED ALWAYS AS column automatically computes the zone from region.
-- Because the function is IMMUTABLE, existing rows are recomputed immediately
-- when the column is added via ALTER TABLE.
-- ============================================================================
ALTER TABLE entities
    ADD COLUMN data_residency_zone TEXT
    GENERATED ALWAYS AS (compute_data_residency_zone(region)) STORED;

-- ============================================================================
-- SECTION 3: Add region_updated_at column for observability
-- ============================================================================
--
-- Gherkin SCENARIO 1: "observability spans include the region attribute
-- for latency tracking"
--
-- This column tracks when the region was last updated (which should never
-- happen due to the immutable field trigger, but we track it for auditing).
-- Observability spans use this to correlate region-based latency metrics.
-- ============================================================================
ALTER TABLE entities
    ADD COLUMN IF NOT EXISTS region_updated_at TIMESTAMPTZ DEFAULT NOW();

-- ============================================================================
-- SECTION 4: Update prevent_immutable_field_update trigger
-- ============================================================================
--
-- Gherkin SCENARIO 3:
--   "When a user attempts to update the data_residency_zone field
--    Then ErrImmutableField is returned"
--
-- The data_residency_zone is a GENERATED ALWAYS AS column — PostgreSQL
-- automatically prevents direct updates to it. The prevent_immutable_field_update
-- trigger from ENTITYMGMT-04 already protects the 'region' field.
--
-- We enhance the trigger to also protect region_updated_at from being
-- set independently (it should only change when region changes, which is
-- prevented by the region immutability check).
-- ============================================================================

-- Drop and recreate the immutable field trigger to add region_updated_at protection
-- The original trigger was created in ENTITYMGMT-04_000_entity_update_optimistic.up.sql
DROP TRIGGER IF EXISTS prevent_immutable_field_update ON entities;

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

    -- data_residency_zone is a generated column; PostgreSQL blocks direct updates anyway,
    -- but we add an explicit check for a clearer error message
    IF OLD.data_residency_zone IS DISTINCT FROM NEW.data_residency_zone THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: data_residency_zone is a generated column and cannot be changed'
            USING HINT = 'Data residency zone is derived from the region field and is immutable.';
    END IF;

    -- region_updated_at must not be set independently (it's derived from region lifecycle)
    IF OLD.region_updated_at IS DISTINCT FROM NEW.region_updated_at
       AND OLD.region IS NOT DISTINCT FROM NEW.region THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: region_updated_at cannot be changed independently of region'
            USING HINT = 'region_updated_at is automatically managed based on region lifecycle.';
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
    -- We allow ONLY: NEW.version = OLD.version + 1 (the optimistic increment).
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
-- SECTION 5: Create enqueue_region_routed_event() function
-- ============================================================================
--
-- Enqueues an entitymanagement.residency.region_routed CloudEvent to the
-- outbox_events table. This is called when:
--   1. A new entity is created (within the same transaction)
--   2. (Future) An entity's routing decision is re-evaluated
--
-- Gherkin SCENARIO 1 mapping:
--   "observability spans include the region attribute for latency tracking"
--     → The ObservabilityContext consumer reads the region_routed event
--       and enriches OpenTelemetry spans with:
--         - entity.region
--         - entity.data_residency_zone
--         - routing_decision (e.g., 'direct_map', 'pass_through')
--
-- Event type: 'entitymanagement.residency.region_routed'
-- Payload per Gherkin spec:
--   { entity_id, region, data_residency_zone, routing_decision, occurred_at }
--
-- Parameters:
--   p_entity_id           UUID   — The entity being routed
--   p_region              TEXT   — The source region (e.g., 'eu-west-1')
--   p_data_residency_zone TEXT   — The resolved zone (e.g., 'eu-west-1')
--   p_routing_decision    TEXT   — 'direct_map' for known regions, 'pass_through' for unknown
--
-- Returns:
--   UUID — The outbox event ID for traceability
--
-- Usage:
--   PERFORM enqueue_region_routed_event(
--     p_entity_id           := 'f0000001-0000-4000-8000-000000000001',
--     p_region              := 'eu-west-1',
--     p_data_residency_zone := 'eu-west-1',
--     p_routing_decision    := 'direct_map'
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION enqueue_region_routed_event(
    p_entity_id           UUID,
    p_region              TEXT,
    p_data_residency_zone TEXT,
    p_routing_decision    TEXT DEFAULT 'direct_map'
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
        'entitymanagement.residency.region_routed',   -- CloudEvents type per Gherkin spec
        '/entity-manager',                              -- Source identifier for EntityManagement context
        'residency/region/' || p_entity_id::TEXT,       -- Subject for event routing
        jsonb_build_object(
            'event_id',            v_event_id::TEXT,
            'entity_id',           p_entity_id::TEXT,
            'region',              p_region,
            'data_residency_zone', p_data_residency_zone,
            'routing_decision',    p_routing_decision,
            'occurred_at',         v_occurred_at
        ),
        'pending',   -- Not yet processed by the outbox relay
        0,           -- Initial retry count
        NULL,        -- No error yet
        v_occurred_at
    )
    RETURNING id INTO v_outbox_id;

    RETURN v_outbox_id::UUID;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION enqueue_region_routed_event(UUID, TEXT, TEXT, TEXT) IS
'Enqueues an entitymanagement.residency.region_routed event for observability span enrichment and routing table updates.';

-- ============================================================================
-- SECTION 6: Update enqueue_entity_created_event to also emit region_routed
-- ============================================================================
--
-- Drop and recreate enqueue_entity_created_event to include the region_routed
-- event emission. The original was created in ENTITYMGMT-02_000_create_entities.up.sql.
--
-- Gherkin SCENARIO 1:
--   "observability spans include the region attribute for latency tracking"
--     → The region_routed event is now emitted alongside entity.created
--       so ObservabilityContext can enrich spans from the start.
-- ============================================================================
DROP FUNCTION IF EXISTS enqueue_entity_created_event(UUID, UUID, VARCHAR, VARCHAR, VARCHAR, TEXT, INTEGER, TEXT, JSONB, JSONB);

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
    v_event_id          UUID;
    v_outbox_id         TEXT;
    v_occurred_at       TIMESTAMPTZ;
    v_routing_decision  TEXT;
    v_region_routed_id  UUID;
BEGIN
    v_event_id    := gen_random_uuid();
    v_occurred_at := NOW();

    -- Determine routing decision based on whether region maps to itself
    -- If region == zone, it's a direct_map; otherwise it's a pass_through
    -- (though with the new function, known regions always map to themselves)
    IF p_region = p_zone THEN
        v_routing_decision := 'direct_map';
    ELSE
        v_routing_decision := 'pass_through';
    END IF;

    -- Step 1: Insert the entity.created event
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

    -- Step 2: Enqueue the region_routed event for observability
    -- Gherkin: "observability spans include the region attribute for latency tracking"
    v_region_routed_id := enqueue_region_routed_event(
        p_entity_id           := p_entity_id,
        p_region              := p_region,
        p_data_residency_zone := p_zone,
        p_routing_decision    := v_routing_decision
    );

    RETURN v_event_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION enqueue_entity_created_event(UUID, UUID, VARCHAR, VARCHAR, VARCHAR, TEXT, INTEGER, TEXT, JSONB, JSONB) IS
'Enqueues entitymanagement.entity.created event PLUS entitymanagement.residency.region_routed event for observability span enrichment.';

-- ============================================================================
-- SECTION 7: Update create_entity_with_idempotency() for new zone mapping
-- ============================================================================
--
-- The function already calls compute_data_residency_zone(p_region) and passes
-- the result to enqueue_entity_created_event(). Since we updated the function
-- and recreated the generated column, this function automatically benefits
-- from the new mapping.
--
-- We recreate it to ensure the generated column value is used consistently
-- and to add region_updated_at initialization.
-- ============================================================================
DROP FUNCTION IF EXISTS create_entity_with_idempotency(UUID, INTEGER, VARCHAR, VARCHAR, VARCHAR, JSONB, JSONB, TEXT, INTEGER);

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
    -- ==========================================================================
    -- Step 1: Check idempotency key (SCENARIO 2)
    -- ==========================================================================
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

    -- ==========================================================================
    -- Step 2: Compute data residency zone using updated function
    -- Gherkin SCENARIO 2: compute_data_residency_zone() now returns
    -- 'eu-west-1' for region 'eu-west-1' (not 'eu' as before)
    -- ==========================================================================
    v_zone := compute_data_residency_zone(p_region);

    -- ==========================================================================
    -- Step 3: Insert the entity
    -- The data_residency_zone GENERATED column will compute automatically,
    -- but we also store v_zone for use in the outbox event.
    -- region_updated_at is initialized to created_at.
    -- ==========================================================================
    INSERT INTO entities (
        id,
        schema_id,
        schema_version,
        name,
        type,
        region,
        status,
        version,
        attributes,
        metadata,
        created_at,
        updated_at,
        region_updated_at
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
        NOW(),
        NOW()                     -- Initialize region_updated_at = created_at
    )
    RETURNING id, version, status::TEXT, created_at
    INTO v_entity_id, v_entity_version, v_entity_status, v_entity_created_at;

    -- ==========================================================================
    -- Step 4: Enqueue entity.created event (also emits region_routed internally)
    -- ==========================================================================
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

    -- ==========================================================================
    -- Step 5: Record idempotency key (if provided) with 7-day TTL
    -- ==========================================================================
    IF p_idempotency_key IS NOT NULL THEN
        PERFORM save_idempotency_key(
            p_request_key := p_idempotency_key,
            p_entity_id   := v_entity_id,
            p_ttl_days    := p_ttl_days
        );
    END IF;

    -- ==========================================================================
    -- Step 6: Return success
    -- ==========================================================================
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

COMMENT ON FUNCTION create_entity_with_idempotency(UUID, INTEGER, VARCHAR, VARCHAR, VARCHAR, JSONB, JSONB, TEXT, INTEGER) IS
'Creates an entity with updated data_residency_zone mapping (one-to-one region→zone). Also emits region_routed event.';

-- ============================================================================
-- SECTION 8: Add indexes for residency-aware query patterns
-- ============================================================================
--
-- These indexes support the observability and routing requirements in
-- Gherkin SCENARIO 1: "observability spans include the region attribute
-- for latency tracking"
--
-- Key query patterns:
--   1. Find all entities in a specific residency zone (region-based routing)
--   2. Track latency by region (observability)
--   3. Filter entities by zone + status (operational queries)
--   4. Count entities per zone (capacity planning)
-- ============================================================================

-- Composite index: zone + region + status (most common residency filter)
-- Used by: "find all active entities in eu-west-1"
CREATE INDEX IF NOT EXISTS idx_entities_zone_region_status
    ON entities(data_residency_zone, region, status);

-- Composite index: zone + created_at (residency-based time-series queries)
-- Used by: ObservabilityContext for latency tracking per zone
CREATE INDEX IF NOT EXISTS idx_entities_zone_created_at
    ON entities(data_residency_zone, created_at DESC);

-- Composite index: region + zone + updated_at (monitoring which regions are active)
-- Used by: RoutingContext for regional routing table updates
CREATE INDEX IF NOT EXISTS idx_entities_region_zone_updated
    ON entities(region, data_residency_zone, updated_at DESC);

-- Partial index: entities in known residency zones (filtering out 'pass_through' regions)
CREATE INDEX IF NOT EXISTS idx_entities_known_zones
    ON entities(data_residency_zone, region)
    WHERE region IN ('eu-west-1', 'eu-west-2', 'eu-west-3', 'eu-central-1',
                     'us-east-1', 'us-east-2', 'us-west-1', 'us-west-2');

-- Index for region_updated_at (observability latency tracking)
CREATE INDEX IF NOT EXISTS idx_entities_region_updated_at
    ON entities(region_updated_at DESC);

-- Composite index: schema + zone (list entities of a type in a specific zone)
CREATE INDEX IF NOT EXISTS idx_entities_schema_zone
    ON entities(schema_id, data_residency_zone);

-- ============================================================================
-- SECTION 9: Add region_routed event index to outbox_events
-- ============================================================================
-- Support efficient querying of region_routed events by ObservabilityContext
CREATE INDEX IF NOT EXISTS idx_outbox_region_routed
    ON outbox_events(created_at DESC)
    WHERE event_type = 'entitymanagement.residency.region_routed';

-- ============================================================================
-- SECTION 10: Diagnostic & validation functions for residency
-- ============================================================================

-- ---------------------------------------------------------------------------
-- FUNCTION: resolve_entity_zone(entity_id)
-- Returns the computed data residency zone for a given entity.
-- Useful for debugging and observability.
--
-- Gherkin SCENARIO 1: Verify that entity's DataResidencyZone is correct
--
-- Usage:
--   SELECT * FROM resolve_entity_zone('f0000001-...');
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION resolve_entity_zone(
    p_entity_id UUID
)
RETURNS TABLE(
    entity_id           UUID,
    region              VARCHAR(64),
    data_residency_zone TEXT,
    routing_decision    TEXT
) AS $$
DECLARE
    v_region VARCHAR(64);
    v_zone   TEXT;
BEGIN
    SELECT e.region, e.data_residency_zone
    INTO v_region, v_zone
    FROM entities e
    WHERE e.id = p_entity_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT
            p_entity_id       AS entity_id,
            NULL::VARCHAR(64) AS region,
            NULL::TEXT        AS data_residency_zone,
            'entity_not_found' AS routing_decision;
        RETURN;
    END IF;

    RETURN QUERY SELECT
        p_entity_id AS entity_id,
        v_region    AS region,
        v_zone      AS data_residency_zone,
        CASE WHEN v_region = v_zone THEN 'direct_map' ELSE 'pass_through' END AS routing_decision;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION resolve_entity_zone(UUID) IS
'Returns the computed data residency zone and routing decision for a given entity.';

-- ---------------------------------------------------------------------------
-- FUNCTION: count_entities_by_zone()
-- Returns entity counts grouped by data_residency_zone.
-- Useful for capacity planning and observability dashboards.
--
-- Gherkin: Capacity planning across regions
--
-- Usage:
--   SELECT * FROM count_entities_by_zone();
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION count_entities_by_zone()
RETURNS TABLE(
    data_residency_zone TEXT,
    total_entities      BIGINT,
    active_entities     BIGINT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        e.data_residency_zone,
        COUNT(*)::BIGINT                                         AS total_entities,
        COUNT(*) FILTER (WHERE e.status = 'active')::BIGINT      AS active_entities
    FROM entities e
    GROUP BY e.data_residency_zone
    ORDER BY e.data_residency_zone;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION count_entities_by_zone() IS
'Returns entity counts grouped by data residency zone for capacity planning.';

-- ---------------------------------------------------------------------------
-- FUNCTION: list_entities_by_zone(data_residency_zone, status, limit, offset)
-- Lists all entities in a given data residency zone, with optional status filter.
--
-- Gherkin: "find all entities in eu-west-1 zone"
--
-- Usage:
--   SELECT * FROM list_entities_by_zone('eu-west-1', 'active', 50, 0);
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION list_entities_by_zone(
    p_data_residency_zone TEXT,
    p_status              entity_status DEFAULT NULL,
    p_limit               INTEGER DEFAULT 100,
    p_offset              INTEGER DEFAULT 0,
    p_include_deleted     BOOLEAN DEFAULT FALSE
)
RETURNS TABLE(
    entity_id           UUID,
    schema_id           UUID,
    schema_version      INTEGER,
    name                VARCHAR(512),
    type                VARCHAR(255),
    region              VARCHAR(64),
    data_residency_zone TEXT,
    status              entity_status,
    version             INTEGER,
    attributes          JSONB,
    metadata            JSONB,
    created_at          TIMESTAMPTZ,
    updated_at          TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        e.id,
        e.schema_id,
        e.schema_version,
        e.name,
        e.type,
        e.region,
        e.data_residency_zone,
        e.status,
        e.version,
        e.attributes,
        e.metadata,
        e.created_at,
        e.updated_at
    FROM entities e
    WHERE e.data_residency_zone = p_data_residency_zone
      AND (p_status IS NULL OR e.status = p_status)
      AND (p_include_deleted OR e.deleted_at IS NULL)
    ORDER BY e.created_at DESC, e.id DESC
    LIMIT p_limit
    OFFSET p_offset;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION list_entities_by_zone(TEXT, entity_status, INTEGER, INTEGER, BOOLEAN) IS
'Lists all entities in a given data residency zone with optional status filter.';

-- ============================================================================
-- SECTION 11: Data migration — recompute existing rows
-- ============================================================================
--
-- Because we dropped and recreated the data_residency_zone generated column,
-- all existing rows are automatically recomputed using the new function.
--
-- Old mappings:  eu-west-1 → 'eu',  us-east-1 → 'us'
-- New mappings:  eu-west-1 → 'eu-west-1',  us-east-1 → 'us-east-1'
--
-- This is a one-time data migration that updates existing entities.
-- It also sets region_updated_at for existing rows.
-- ============================================================================
DO $$
DECLARE
    v_updated BIGINT;
BEGIN
    -- Set region_updated_at for existing rows that don't have it
    UPDATE entities
    SET region_updated_at = created_at
    WHERE region_updated_at IS NULL;

    GET DIAGNOSTICS v_updated = ROW_COUNT;
    RAISE NOTICE 'ENTITYMGMT-11: Updated region_updated_at for % existing entities', v_updated;
END $$;

-- ============================================================================
-- SECTION 12: Notification for dependent services
-- ============================================================================
--
-- Log a notice to inform operators that the zone mapping has changed.
-- This ensures that any downstream consumers (ObservabilityContext,
-- RoutingContext) are aware of the new one-to-one mapping.
-- ============================================================================
DO $$
BEGIN
    RAISE NOTICE 'ENTITYMGMT-11: compute_data_residency_zone() updated.';
    RAISE NOTICE '  Old behavior: eu-west-1 → eu, us-east-1 → us';
    RAISE NOTICE '  New behavior: eu-west-1 → eu-west-1, us-east-1 → us-east-1';
    RAISE NOTICE '  Unknown regions pass through as-is (unchanged).';
    RAISE NOTICE '  Existing rows recomputed via generated column recreation.';
    RAISE NOTICE '  New event: entitymanagement.residency.region_routed';
    RAISE NOTICE '  Consumers: ObservabilityContext, RoutingContext';
END $$;

COMMIT;
