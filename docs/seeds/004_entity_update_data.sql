-- Seed: 004_entity_update_data.sql
-- Description: ENT-03: Update Entity — Seed data demonstrating entity update
-- scenarios matching the Gherkin acceptance criteria.
--
-- This seed:
--   1. Ensures the "ServiceComponent" schema and "api-gateway" entity exist
--      (referenced by ENT-02 seed, but included here for standalone runs)
--   2. Demonstrates a successful entity update (status: active → inactive)
--   3. Seeds audit log entries for the update history
--   4. Seeds event_outbox with EntityUpdated events for traceability
--   5. Demonstrates metadata updates (Gherkin: { "deprecated_at": "2025-01-15" })

-- ============================================================================
-- Prerequisite Check
-- Ensure the base schema and entity exist from ENT-02 seeds.
-- This seed is designed to be run after 003_entity_data.sql.
-- ============================================================================

-- ============================================================================
-- Seed 1: Verify/demonstrate entity state before update
-- The api-gateway entity starts as status='active' with region='us-east-1'
-- ============================================================================
DO $$
DECLARE
    v_entity_id UUID := 'a1000001-0000-4000-8000-000000000001';
    v_entity_name TEXT;
    v_entity_status TEXT;
    v_entity_region TEXT;
BEGIN
    SELECT name, status::TEXT, region
    INTO v_entity_name, v_entity_status, v_entity_region
    FROM entities
    WHERE id = v_entity_id;

    RAISE NOTICE 'Pre-update state: entity=% name=% status=% region=%',
        v_entity_id, v_entity_name, v_entity_status, v_entity_region;
END $$;

-- ============================================================================
-- Seed 2: Demonstrate entity update — status change to 'inactive'
-- This mirrors the Gherkin scenario:
--   PUT /api/v1/entities/ent-123 { "status": "inactive", "metadata": { "deprecated_at": "2025-01-15" } }
--
-- The update is performed via a direct UPDATE to entities, which triggers:
--   1. prevent_entity_immutable_field_update (BEFORE) — validates no immutable fields changed
--   2. update_entities_modtime (BEFORE) — sets updated_at = NOW()
--   3. after_entity_update (AFTER) — writes to entity_audit_log + event_outbox
-- ============================================================================
UPDATE entities
SET
    status = 'inactive',
    metadata = jsonb_build_object(
        'deprecated_at', '2025-01-15',
        'reason', 'Migrating to v2 service mesh',
        'updated_by', 'platform-admin'
    ),
    attributes = attributes || jsonb_build_object(
        'deprecation_notice', 'This component is scheduled for decommission'
    )
WHERE id = 'a1000001-0000-4000-8000-000000000001'
  AND name = 'api-gateway';

-- ============================================================================
-- Seed 3: Demonstrate entity re-activation (inactive → active)
-- The status lifecycle allows re-activation: inactive → active
-- ============================================================================
UPDATE entities
SET
    status = 'active',
    metadata = jsonb_build_object(
        'reactivated_at', NOW()::TEXT,
        'reason', 'Rollback from v2 migration — v1 restored'
    )
WHERE id = 'a1000001-0000-4000-8000-000000000001'
  AND name = 'api-gateway';

-- ============================================================================
-- Seed 4: Update entity name (mutable field)
-- ============================================================================
UPDATE entities
SET
    name = 'api-gateway-v2',
    metadata = jsonb_build_object(
        'renamed_at', NOW()::TEXT,
        'previous_name', 'api-gateway',
        'reason', 'Version 2 naming convention'
    )
WHERE id = 'a1000001-0000-4000-8000-000000000001';

-- Reset name back for test consistency
UPDATE entities
SET
    name = 'api-gateway',
    metadata = jsonb_build_object(
        'name_reset_at', NOW()::TEXT,
        'previous_name', 'api-gateway-v2',
        'reason', 'Reset for test consistency'
    )
WHERE id = 'a1000001-0000-4000-8000-000000000001';

-- ============================================================================
-- Seed 5: Demonstrate metadata-only update
-- Gherkin scenario: update with { "metadata": { "deprecated_at": "2025-01-15" } }
--
-- The metadata column accepts arbitrary JSONB. Only the 'metadata' field
-- appears in changed_fields.
-- ============================================================================
UPDATE entities
SET
    metadata = jsonb_build_object(
        'deprecated_at', '2025-01-15',
        'owner', 'platform-team',
        'ticket', 'OPS-4421',
        'reason', 'Planned deprecation per OPS-4421'
    )
WHERE id = 'a1000001-0000-4000-8000-000000000002'  -- user-service entity
  AND name = 'user-service';

-- ============================================================================
-- Seed 6: Demonstrate schema version update
-- When an entity is migrated to a new schema version, schema_version changes
-- ============================================================================
UPDATE entities
SET
    schema_version = 2,
    metadata = jsonb_build_object(
        'schema_migration', 'v1_to_v2',
        'migrated_at', NOW()::TEXT,
        'added_fields', jsonb_build_array('owner', 'cost_center')
    )
WHERE id = 'a1000001-0000-4000-8000-000000000003'  -- analytics-pipeline entity
  AND name = 'analytics-pipeline';

-- ============================================================================
-- Seed 7: Verify audit log entries
-- Demonstrates that the audit log captures every update above
-- ============================================================================
DO $$
DECLARE
    v_entity_id UUID := 'a1000001-0000-4000-8000-000000000001';
    v_audit_count INTEGER;
BEGIN
    SELECT COUNT(*)
    INTO v_audit_count
    FROM entity_audit_log
    WHERE entity_id = v_entity_id;

    RAISE NOTICE 'Entity % has % audit log entries', v_entity_id, v_audit_count;

    -- Show the most recent entries
    RAISE NOTICE '--- Recent Audit Log Entries ---';
    FOR rec IN
        SELECT
            eal.logged_at,
            eal.changed_fields,
            eal.new_state->>'status' AS new_status,
            eal.previous_state->>'status' AS old_status
        FROM entity_audit_log eal
        WHERE eal.entity_id = v_entity_id
        ORDER BY eal.logged_at DESC
        LIMIT 5
    LOOP
        RAISE NOTICE 'At %: Changed=[%] Status: % → %',
            rec.logged_at,
            array_to_string(rec.changed_fields, ', '),
            rec.old_status,
            rec.new_status;
    END LOOP;
END $$;

-- ============================================================================
-- Seed 8: Verify event_outbox entries for EntityUpdated
-- ============================================================================
DO $$
DECLARE
    v_outbox_count INTEGER;
BEGIN
    SELECT COUNT(*)
    INTO v_outbox_count
    FROM event_outbox
    WHERE event_type = 'entity.EntityUpdated';

    RAISE NOTICE 'Total EntityUpdated events in outbox: %', v_outbox_count;

    -- Show the most recent events
    RAISE NOTICE '--- Recent EntityUpdated Events ---';
    FOR rec IN
        SELECT
            eo.created_at,
            eo.data->>'entityId' AS entity_id,
            eo.data->>'entityName' AS entity_name,
            eo.data->>'changedFields' AS changed_fields
        FROM event_outbox eo
        WHERE eo.event_type = 'entity.EntityUpdated'
        ORDER BY eo.created_at DESC
        LIMIT 5
    LOOP
        RAISE NOTICE 'At %: Entity=[%] Name=[%] Changed=%',
            rec.created_at,
            rec.entity_id,
            rec.entity_name,
            rec.changed_fields;
    END LOOP;
END $$;

-- ============================================================================
-- Seed 9: Demonstrate get_entity_update_history() function
-- ============================================================================
SELECT * FROM get_entity_update_history('a1000001-0000-4000-8000-000000000001', 3);

-- ============================================================================
-- Summary: Verify final entity state
-- ============================================================================
DO $$
DECLARE
    v_id UUID := 'a1000001-0000-4000-8000-000000000001';
    v_name TEXT;
    v_status TEXT;
    v_region TEXT;
    v_metadata JSONB;
    v_updated_at TIMESTAMPTZ;
BEGIN
    SELECT name, status::TEXT, region, metadata, updated_at
    INTO v_name, v_status, v_region, v_metadata, v_updated_at
    FROM entities
    WHERE id = v_id;

    RAISE NOTICE '=== Final Entity State ===';
    RAISE NOTICE 'ID:       %', v_id;
    RAISE NOTICE 'Name:     %', v_name;
    RAISE NOTICE 'Status:   %', v_status;
    RAISE NOTICE 'Region:   %', v_region;
    RAISE NOTICE 'Metadata: %', v_metadata;
    RAISE NOTICE 'Updated:  %', v_updated_at;
END $$;
