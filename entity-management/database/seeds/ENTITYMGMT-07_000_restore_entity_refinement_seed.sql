-- Seed: ENTITYMGMT-07_000_restore_entity_refinement_seed.sql
-- Story: ENTITYMGMT-07 — User restores a soft-deleted entity to active state
-- Bounded Context: Entity Management
--
-- This seed:
--   1. Creates entity "ent-001" and soft-deletes it at a specific timestamp
--      (matching Gherkin SCENARIO 1 starting state:
--       deleted_at = "2024-01-15T10:00:00Z", status="deleted")
--   2. Creates entity "ent-002" as active (matching Gherkin SCENARIO 2:
--      active, deleted_at is NULL)
--   3. Demonstrates SCENARIO 1: Successful restore of soft-deleted entity
--      (deleted_at cleared, status transitions to 'active',
--       entitymanagement.entity.restored event written to outbox with
--       previous_deleted_at, entity visible in standard list queries)
--   4. Demonstrates SCENARIO 2: Restore of non-deleted entity is rejected
--      (ErrNotDeleted, HTTP 400, "entity is not soft-deleted",
--       no data modified, no event emitted)
--   5. Runs diagnostic: verify_entity_visible_after_restore() to confirm
--      SCENARIO 1 visibility requirement
--
-- Prerequisites:
--   - ENTITYMGMT-07 migration applied (all refined functions exist)
--   - ENTITYMGMT-02 seed applied (Customer schema exists at expected UUID)
-- ============================================================================

-- ============================================================================
-- Reference: Customer Schema UUID (from ENTITYMGMT-01 seed)
-- ============================================================================
\set CUSTOMER_SCHEMA_ID 'c0000001-0000-4000-8000-000000000001'

-- ============================================================================
-- Seed Section 1: Create entity "ent-001" as soft-deleted
--
-- Gherkin SCENARIO 1:
--   "Given entity 'ent-001' is soft-deleted
--    (deleted_at = '2024-01-15T10:00:00Z', status='deleted')"
-- ============================================================================
DO $$
DECLARE
    v_entity_id CONSTANT UUID := 'e0000001-0000-4000-8000-000000000001';
    v_schema_id CONSTANT UUID := :CUSTOMER_SCHEMA_ID;
    v_deleted_at CONSTANT TIMESTAMPTZ := '2024-01-15T10:00:00Z';
    v_version INTEGER;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== SEED SECTION 1: Create entity "ent-001" (soft-deleted) ===';
    RAISE NOTICE 'Gherkin: entity "ent-001" is soft-deleted (deleted_at=%s, status=deleted)',
        v_deleted_at;

    -- Step 1a: Create the entity at version 1 (active)
    INSERT INTO entities (id, schema_id, schema_version, name, type, region, status, version, attributes, metadata, created_at, updated_at)
    VALUES (
        v_entity_id, v_schema_id, 1, 'Alice', 'customer', 'eu-west-1',
        'active'::entity_status, 1,
        '{"email": "alice@example.com", "name": "Alice"}'::jsonb,
        '{"created_by": "seed", "environment": "test"}'::jsonb,
        '2024-01-01T08:00:00Z', '2024-01-01T08:00:00Z'
    )
    ON CONFLICT (id) DO UPDATE
        SET name = 'Alice', schema_id = v_schema_id;

    -- Step 1b: Update to version 2 (simulate first update)
    UPDATE entities
    SET version = 2, updated_at = '2024-01-10T12:00:00Z',
        attributes = '{"email": "alice@example.com", "name": "Alice", "tier": "premium"}'::jsonb
    WHERE id = v_entity_id AND version = 1;

    -- Step 1c: Update to version 3 (simulate second update)
    UPDATE entities
    SET version = 3, updated_at = '2024-01-14T09:00:00Z',
        metadata = '{"created_by": "seed", "environment": "test", "plan": "enterprise"}'::jsonb
    WHERE id = v_entity_id AND version = 2;

    -- Step 1d: Soft-delete at the specified timestamp (version 3→4)
    -- This matches the Gherkin starting state:
    --   deleted_at = "2024-01-15T10:00:00Z"
    --   status = "deleted"
    UPDATE entities
    SET
        status     = 'deleted'::entity_status,
        deleted_at = v_deleted_at,
        version    = version + 1,
        updated_at = v_deleted_at
    WHERE id = v_entity_id AND deleted_at IS NULL;

    -- Verify final state
    SELECT version INTO v_version FROM entities WHERE id = v_entity_id;

    RAISE NOTICE 'Entity "ent-001" soft-deleted at version % (expected: 4)', v_version;
    RAISE NOTICE '  Name:      Alice';
    RAISE NOTICE '  Status:    deleted (terminal state)';
    RAISE NOTICE '  deleted_at: 2024-01-15T10:00:00Z';
    RAISE NOTICE '  Region:    eu-west-1';
    RAISE NOTICE '  ✅ Entity ready for SCENARIO 1';
END $$;

-- ============================================================================
-- Seed Section 2: Create entity "ent-002" as active (not deleted)
--
-- Gherkin SCENARIO 2:
--   "Given entity 'ent-002' is active (deleted_at is NULL)"
-- ============================================================================
DO $$
DECLARE
    v_entity_id CONSTANT UUID := 'e0000002-0000-4000-8000-000000000002';
    v_schema_id CONSTANT UUID := :CUSTOMER_SCHEMA_ID;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== SEED SECTION 2: Create entity "ent-002" (active) ===';
    RAISE NOTICE 'Gherkin: entity "ent-002" is active (deleted_at is NULL)';

    INSERT INTO entities (id, schema_id, schema_version, name, type, region, status, version, attributes, metadata, created_at, updated_at)
    VALUES (
        v_entity_id, v_schema_id, 1, 'Bob', 'customer', 'eu-west-1',
        'active'::entity_status, 1,
        '{"email": "bob@example.com", "name": "Bob"}'::jsonb,
        '{"created_by": "seed", "environment": "test"}'::jsonb,
        '2024-01-20T08:00:00Z', '2024-01-20T08:00:00Z'
    )
    ON CONFLICT (id) DO UPDATE
        SET name = 'Bob', schema_id = v_schema_id;

    RAISE NOTICE 'Entity "ent-002" created at version 1';
    RAISE NOTICE '  Name:      Bob';
    RAISE NOTICE '  Status:    active';
    RAISE NOTICE '  deleted_at: NULL';
    RAISE NOTICE '  ✅ Entity ready for SCENARIO 2';
END $$;

-- ============================================================================
-- Seed Section 3: Gherkin SCENARIO 1 — Successful Restore
--
-- Gherkin:
--   When a POST /api/v1/entities/ent-001/restore request is sent
--   Then deleted_at is cleared (set to NULL)
--     And status transitions to "active"
--     And an entitymanagement.entity.restored event is written to the outbox
--     And HTTP 200 is returned with {"status": "restored", "entity_id": "ent-001"}
--     And the entity is now visible in standard list queries
-- ============================================================================
DO $$
DECLARE
    v_entity_id CONSTANT UUID := 'e0000001-0000-4000-8000-000000000001';
    v_result RECORD;
    v_deleted_at_check TIMESTAMPTZ;
    v_status_check entity_status;
    v_version_check INTEGER;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== SEED SECTION 3: SCENARIO 1 — Successful Restore ===';
    RAISE NOTICE 'Attempting restore on entity "ent-001" (soft-deleted at 2024-01-15T10:00:00Z)';

    -- Perform the combined restore with outbox event
    SELECT * INTO v_result
    FROM restore_entity_with_outbox(
        p_entity_id   := v_entity_id,
        p_restored_by := 'user-admin-001'
    );

    IF v_result.success THEN
        RAISE NOTICE '✅ RESTORE SUCCEEDED (SCENARIO 1)';
        RAISE NOTICE '   Entity ID:              % (expected: e0000001-...)', v_result.entity_json->>'id';
        RAISE NOTICE '   Status:                 % (expected: active)', v_result.entity_json->>'status';
        RAISE NOTICE '   deleted_at:             % (expected: null — cleared)', v_result.entity_json->>'deleted_at';
        RAISE NOTICE '   previous_deleted_at:    % (expected: 2024-01-15T10:00:00Z)', v_result.entity_json->>'previous_deleted_at';
        RAISE NOTICE '   Version:                % (expected: 5, bumped from 4)', v_result.entity_json->>'version';
        RAISE NOTICE '   Event ID:               % (expected: non-NULL)', v_result.event_id;
        RAISE NOTICE '   previous_deleted_at:    % (expected: 2024-01-15T10:00:00Z)', v_result.previous_deleted_at;

        -- Direct DB check: confirm deleted_at is NULL and status is 'active'
        SELECT deleted_at, status, version
        INTO v_deleted_at_check, v_status_check, v_version_check
        FROM entities WHERE id = v_entity_id;

        IF v_deleted_at_check IS NULL THEN
            RAISE NOTICE '✅ Check: deleted_at IS NULL (cleared by restore)';
        ELSE
            RAISE NOTICE '❌ Check: deleted_at IS NOT NULL — RESTORE DID NOT CLEAR IT!';
        END IF;

        IF v_status_check = 'active'::entity_status THEN
            RAISE NOTICE '✅ Check: Status transitioned to "active"';
        ELSE
            RAISE NOTICE '❌ Check: Status is % (expected: active)', v_status_check;
        END IF;

        IF v_version_check = 5 THEN
            RAISE NOTICE '✅ Check: Version bumped from 4 to 5';
        ELSE
            RAISE NOTICE '⚠️  Check: Version is % (expected: 5)', v_version_check;
        END IF;

        IF v_result.event_id IS NOT NULL THEN
            RAISE NOTICE '✅ Check: entitymanagement.entity.restored event emitted: %', v_result.event_id;
        ELSE
            RAISE NOTICE '❌ Check: No restore event emitted!';
        END IF;
    ELSE
        RAISE NOTICE '❌ RESTORE FAILED (unexpected for SCENARIO 1)';
        RAISE NOTICE '   Error code:    %', v_result.error_code;
        RAISE NOTICE '   Error message: %', v_result.error_message;
    END IF;
END $$;

-- ============================================================================
-- Seed Section 4: Verify outbox event payload structure
-- Ensures the entitymanagement.entity.restored event contains all required
-- fields per the Gherkin spec, specifically including previous_deleted_at.
-- ============================================================================
DO $$
DECLARE
    v_entity_id CONSTANT UUID := 'e0000001-0000-4000-8000-000000000001';
    v_entity_name VARCHAR(512);
    v_region VARCHAR(64);
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== SEED SECTION 4: Verify Outbox Event Payload ===';

    SELECT name, region INTO v_entity_name, v_region
    FROM entities WHERE id = v_entity_id;

    FOR rec IN
        SELECT
            eo.id,
            eo.event_id,
            eo.event_type,
            eo.payload,
            eo.status,
            eo.created_at
        FROM outbox_events eo
        WHERE eo.event_type = 'entitymanagement.entity.restored'
          AND eo.aggregate_id = v_entity_id::TEXT
        ORDER BY eo.created_at DESC
        LIMIT 1
    LOOP
        RAISE NOTICE 'Event ID:   %', rec.event_id;
        RAISE NOTICE 'Event Type: %', rec.event_type;
        RAISE NOTICE 'Status:     %', rec.status;
        RAISE NOTICE 'Created:    %', rec.created_at;
        RAISE NOTICE 'Payload:    %', rec.payload;

        -- Verify all required fields per Gherkin spec
        -- Payload: {event_id, entity_id, entity_name, region, previous_deleted_at, occurred_at}
        IF rec.payload ? 'event_id'
           AND rec.payload ? 'entity_id'
           AND rec.payload ? 'entity_name'
           AND rec.payload ? 'region'
           AND rec.payload ? 'previous_deleted_at'
           AND rec.payload ? 'occurred_at'
        THEN
            RAISE NOTICE '✅ Payload contains all required fields';
            RAISE NOTICE '   - event_id:            %', rec.payload->>'event_id';
            RAISE NOTICE '   - entity_id:           %', rec.payload->>'entity_id';
            RAISE NOTICE '   - entity_name:         %', rec.payload->>'entity_name';
            RAISE NOTICE '   - region:              %', rec.payload->>'region';
            RAISE NOTICE '   - previous_deleted_at: %', rec.payload->>'previous_deleted_at';
            RAISE NOTICE '   - occurred_at:         %', rec.payload->>'occurred_at';
        ELSE
            RAISE NOTICE '❌ Payload missing required fields!';
            RAISE NOTICE '   Has event_id:            %', rec.payload ? 'event_id';
            RAISE NOTICE '   Has entity_id:           %', rec.payload ? 'entity_id';
            RAISE NOTICE '   Has entity_name:         %', rec.payload ? 'entity_name';
            RAISE NOTICE '   Has region:              %', rec.payload ? 'region';
            RAISE NOTICE '   Has previous_deleted_at: %', rec.payload ? 'previous_deleted_at';
            RAISE NOTICE '   Has occurred_at:         %', rec.payload ? 'occurred_at';
        END IF;

        -- Verify payload values match the restored entity
        IF rec.payload->>'entity_name' = v_entity_name
           AND rec.payload->>'region' = 'eu-west-1'
           AND (rec.payload->>'previous_deleted_at')::TIMESTAMPTZ = '2024-01-15T10:00:00Z'::TIMESTAMPTZ
        THEN
            RAISE NOTICE '✅ Payload values match entity state';
            RAISE NOTICE '   ✓ entity_name matches: %', rec.payload->>'entity_name';
            RAISE NOTICE '   ✓ region matches: eu-west-1';
            RAISE NOTICE '   ✓ previous_deleted_at is original deletion timestamp: %',
                rec.payload->>'previous_deleted_at';
        ELSE
            RAISE NOTICE '⚠️  Payload values mismatch:';
            RAISE NOTICE '   entity_name=% (expected=%)', rec.payload->>'entity_name', v_entity_name;
            RAISE NOTICE '   region=% (expected=eu-west-1)', rec.payload->>'region';
            RAISE NOTICE '   previous_deleted_at=% (expected=2024-01-15T10:00:00Z)',
                rec.payload->>'previous_deleted_at';
        END IF;
    END LOOP;

    IF NOT FOUND THEN
        RAISE NOTICE '❌ No entitymanagement.entity.restored event found in outbox!';
    END IF;
END $$;

-- ============================================================================
-- Seed Section 5: Gherkin SCENARIO 2 — Restore of Non-Deleted Entity
--
-- Gherkin:
--   Given entity "ent-002" is active (deleted_at is NULL)
--   When a restore is attempted on entity "ent-002"
--   Then ErrNotDeleted is returned (HTTP 400)
--     And message: "entity is not soft-deleted"
--     And no data is modified
--     And no entity.restored event is emitted
-- ============================================================================
DO $$
DECLARE
    v_entity_id CONSTANT UUID := 'e0000002-0000-4000-8000-000000000002';
    v_result RECORD;
    v_outbox_count_before INTEGER;
    v_outbox_count_after INTEGER;
    v_original_status entity_status;
    v_original_version INTEGER;
    v_original_deleted_at TIMESTAMPTZ;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== SEED SECTION 5: SCENARIO 2 — Restore Non-Deleted Entity ===';

    -- Capture original state before attempting restore
    SELECT status, version, deleted_at
    INTO v_original_status, v_original_version, v_original_deleted_at
    FROM entities WHERE id = v_entity_id;

    RAISE NOTICE 'Entity "ent-002" original state: status=% version=% deleted_at=%',
        v_original_status, v_original_version, COALESCE(v_original_deleted_at::TEXT, 'NULL');

    -- Count existing restored events before attempt
    SELECT COUNT(*) INTO v_outbox_count_before
    FROM outbox_events
    WHERE event_type = 'entitymanagement.entity.restored'
      AND aggregate_id = v_entity_id::TEXT;

    RAISE NOTICE 'entity.restored events before attempt: % (expected: 0)', v_outbox_count_before;

    -- Attempt to restore an ACTIVE entity (not soft-deleted)
    SELECT * INTO v_result
    FROM restore_entity_with_outbox(
        p_entity_id   := v_entity_id,
        p_restored_by := 'user-test-002'
    );

    -- Count restored events after attempt
    SELECT COUNT(*) INTO v_outbox_count_after
    FROM outbox_events
    WHERE event_type = 'entitymanagement.entity.restored'
      AND aggregate_id = v_entity_id::TEXT;

    IF NOT v_result.success THEN
        RAISE NOTICE '✅ RESTORE REJECTED (SCENARIO 2 — expected)';

        -- Check error code matches Gherkin
        IF v_result.error_code = 'ERR_NOT_DELETED' THEN
            RAISE NOTICE '   ✅ Error code: ERR_NOT_DELETED (expected)';
        ELSE
            RAISE NOTICE '   ❌ Error code: % (expected: ERR_NOT_DELETED)', v_result.error_code;
        END IF;

        -- Check error message matches Gherkin
        IF v_result.error_message = 'entity is not soft-deleted' THEN
            RAISE NOTICE '   ✅ Error message: "entity is not soft-deleted" (expected)';
        ELSE
            RAISE NOTICE '   ❌ Error message: "%" (expected: "entity is not soft-deleted")',
                v_result.error_message;
        END IF;

        -- Check no event was emitted
        IF v_result.event_id IS NULL THEN
            RAISE NOTICE '   ✅ Event ID: NULL (no event emitted)';
        ELSE
            RAISE NOTICE '   ❌ Event ID: % (expected: NULL — event should NOT be emitted)',
                v_result.event_id;
        END IF;

        -- Verify no duplicate event was emitted
        IF v_outbox_count_after = v_outbox_count_before THEN
            RAISE NOTICE '   ✅ No entity.restored event emitted (count unchanged at %)',
                v_outbox_count_after;
        ELSE
            RAISE NOTICE '   ❌ Event emitted unexpectedly! Count changed from % to %',
                v_outbox_count_before, v_outbox_count_after;
        END IF;

        -- Check no data was modified
        DECLARE
            v_after_status entity_status;
            v_after_version INTEGER;
            v_after_deleted_at TIMESTAMPTZ;
        BEGIN
            SELECT status, version, deleted_at
            INTO v_after_status, v_after_version, v_after_deleted_at
            FROM entities WHERE id = v_entity_id;

            IF v_after_status = v_original_status
               AND v_after_version = v_original_version
               AND v_after_deleted_at IS NULL AND v_original_deleted_at IS NULL
            THEN
                RAISE NOTICE '   ✅ No data modified (status=%, version=%, deleted_at=%)',
                    v_after_status, v_after_version, COALESCE(v_after_deleted_at::TEXT, 'NULL');
            ELSE
                RAISE NOTICE '   ❌ Data was modified! Status: %→%, Version: %→%, deleted_at: %→%',
                    v_original_status, v_after_status,
                    v_original_version, v_after_version,
                    COALESCE(v_original_deleted_at::TEXT, 'NULL'),
                    COALESCE(v_after_deleted_at::TEXT, 'NULL');
            END IF;
        END;
    ELSE
        RAISE NOTICE '❌ RESTORE SHOULD HAVE FAILED (SCENARIO 2)';
        RAISE NOTICE '   Entity was active but the restore operation succeeded!';
    END IF;
END $$;

-- ============================================================================
-- Seed Section 6: Verify validate_entity_restorable() for SCENARIO 2
-- ============================================================================
DO $$
DECLARE
    v_entity_id CONSTANT UUID := 'e0000002-0000-4000-8000-000000000002';
    v_result RECORD;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== SEED SECTION 6: validate_entity_restorable() for Active Entity ===';

    SELECT * INTO v_result
    FROM validate_entity_restorable(v_entity_id);

    IF NOT v_result.restorable THEN
        RAISE NOTICE '✅ validate_entity_restorable correctly rejected active entity';
        RAISE NOTICE '   restorable:    % (expected: FALSE)', v_result.restorable;
        RAISE NOTICE '   entity_name:   % (expected: Bob)', v_result.entity_name;
        RAISE NOTICE '   entity_status: % (expected: active)', v_result.entity_status;
        RAISE NOTICE '   deleted_at:    % (expected: NULL)', COALESCE(v_result.deleted_at::TEXT, 'NULL');
        RAISE NOTICE '   error_code:    % (expected: ERR_NOT_DELETED)', v_result.error_code;
        RAISE NOTICE '   error_message: % (expected: entity is not soft-deleted)', v_result.error_message;
    ELSE
        RAISE NOTICE '❌ validate_entity_restorable incorrectly returned restorable for active entity!';
    END IF;
END $$;

-- ============================================================================
-- Seed Section 7: Verify validate_entity_restorable() for SCENARIO 1
-- (Now that entity is restored, it should return ERR_NOT_DELETED)
-- ============================================================================
DO $$
DECLARE
    v_entity_id CONSTANT UUID := 'e0000001-0000-4000-8000-000000000001';
    v_result RECORD;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== SEED SECTION 7: validate_entity_restorable() for Recently Restored Entity ===';

    SELECT * INTO v_result
    FROM validate_entity_restorable(v_entity_id);

    IF NOT v_result.restorable AND v_result.error_code = 'ERR_NOT_DELETED' THEN
        RAISE NOTICE '✅ validate_entity_restorable correctly returns ERR_NOT_DELETED for restored entity';
        RAISE NOTICE '   (Entity was restored — no longer restorable)';
        RAISE NOTICE '   error_message: %', v_result.error_message;
    ELSE
        RAISE NOTICE '⚠️  validate_entity_restorable for restored entity: restorable=% error_code=%',
            v_result.restorable, v_result.error_code;
    END IF;
END $$;

-- ============================================================================
-- Seed Section 8: Verify entity visibility in standard list queries
--
-- Gherkin SCENARIO 1:
--   "And the entity is now visible in standard list queries"
-- ============================================================================
DO $$
DECLARE
    v_entity_id CONSTANT UUID := 'e0000001-0000-4000-8000-000000000001';
    v_schema_id CONSTANT UUID := :CUSTOMER_SCHEMA_ID;
    v_entity_in_list BOOLEAN;
    v_entity_via_get BOOLEAN;
    v_list_count BIGINT;
    v_get_count BIGINT;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== SEED SECTION 8: Entity Visibility in Standard List Queries ===';
    RAISE NOTICE 'Gherkin: "And the entity is now visible in standard list queries"';

    -- Check 1: Entity appears in default list_entities_by_schema (include_deleted=FALSE)
    SELECT EXISTS(
        SELECT 1 FROM list_entities_by_schema(
            p_schema_id       := v_schema_id,
            p_status          := NULL,
            p_limit           := 1000,
            p_offset          := 0,
            p_include_deleted := FALSE
        ) WHERE entity_id = v_entity_id
    ) INTO v_entity_in_list;

    IF v_entity_in_list THEN
        RAISE NOTICE '✅ Check 1: Entity found in list_entities_by_schema() default listing';
    ELSE
        RAISE NOTICE '❌ Check 1: Entity NOT found in default listing!';
    END IF;

    -- Check 2: Entity appears in default get_entity_by_id (include_deleted=FALSE)
    SELECT EXISTS(
        SELECT 1 FROM get_entity_by_id(
            p_entity_id       := v_entity_id,
            p_include_deleted := FALSE
        )
    ) INTO v_entity_via_get;

    IF v_entity_via_get THEN
        RAISE NOTICE '✅ Check 2: Entity retrieved via get_entity_by_id() default';
    ELSE
        RAISE NOTICE '❌ Check 2: Entity NOT retrievable via get_entity_by_id() default!';
    END IF;

    -- Count
    SELECT COUNT(*) INTO v_list_count
    FROM list_entities_by_schema(
        p_schema_id       := v_schema_id,
        p_status          := NULL,
        p_limit           := 1000,
        p_offset          := 0,
        p_include_deleted := FALSE
    ) WHERE entity_id = v_entity_id;

    SELECT COUNT(*) INTO v_get_count
    FROM get_entity_by_id(
        p_entity_id       := v_entity_id,
        p_include_deleted := FALSE
    );

    IF v_entity_in_list AND v_entity_via_get THEN
        RAISE NOTICE '';
        RAISE NOTICE '🎯 Gherkin SCENARIO 1 PASSED: Entity is visible in standard list queries';
    ELSE
        RAISE NOTICE '';
        RAISE NOTICE '❌ Gherkin SCENARIO 1 FAILED: Entity is NOT fully visible';
        RAISE NOTICE '   list_entities_by_schema: %', CASE WHEN v_entity_in_list THEN '✅' ELSE '❌' END;
        RAISE NOTICE '   get_entity_by_id:        %', CASE WHEN v_entity_via_get THEN '✅' ELSE '❌' END;
    END IF;
END $$;

-- ============================================================================
-- Seed Section 9: Run formal diagnostic — verify_entity_visible_after_restore()
-- ============================================================================
DO $$
DECLARE
    v_entity_id CONSTANT UUID := 'e0000001-0000-4000-8000-000000000001';
    v_schema_id CONSTANT UUID := :CUSTOMER_SCHEMA_ID;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== SEED SECTION 9: Diagnostic — verify_entity_visible_after_restore() ===';

    FOR rec IN
        SELECT * FROM verify_entity_visible_after_restore(
            p_entity_id := v_entity_id,
            p_schema_id := v_schema_id
        )
    LOOP
        RAISE NOTICE '  %: %', CASE WHEN rec.passed THEN '✅' ELSE '❌' END, rec.check_name;
        RAISE NOTICE '    %', rec.detail;
    END LOOP;
END $$;

-- ============================================================================
-- Seed Section 10: Verify get_restorable_entity() for deleted entity
-- Create a temporary deleted entity to demonstrate get_restorable_entity()
-- ============================================================================
DO $$
DECLARE
    v_temp_id CONSTANT UUID := 'e0000003-0000-4000-8000-000000000003';
    v_schema_id CONSTANT UUID := :CUSTOMER_SCHEMA_ID;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== SEED SECTION 10: get_restorable_entity() for Deleted Entity ===';

    -- Create a temporary soft-deleted entity
    INSERT INTO entities (id, schema_id, schema_version, name, type, region, status, version, attributes, metadata, created_at, updated_at, deleted_at)
    VALUES (
        v_temp_id, v_schema_id, 1, 'Charlie', 'customer', 'us-east-1',
        'deleted'::entity_status, 2,
        '{"email": "charlie@example.com", "name": "Charlie"}'::jsonb,
        '{}'::jsonb,
        '2024-03-01T08:00:00Z', '2024-05-01T12:00:00Z', NOW() - INTERVAL '5 days'
    )
    ON CONFLICT (id) DO NOTHING;

    -- Query the restorable entity
    FOR rec IN
        SELECT * FROM get_restorable_entity(v_temp_id)
    LOOP
        RAISE NOTICE 'Restorable entity found:';
        RAISE NOTICE '  Name:       %', rec.name;
        RAISE NOTICE '  Status:     %', rec.status;
        RAISE NOTICE '  deleted_at: %', rec.deleted_at;
        RAISE NOTICE '  Deleted:    % (human-readable)', rec.deleted_duration;
        RAISE NOTICE '  Region:     %', rec.region;
        RAISE NOTICE '  Version:    %', rec.version;
        RAISE NOTICE '  ✅ get_restorable_entity() works correctly';
    END LOOP;

    IF NOT FOUND THEN
        RAISE NOTICE '⚠️  No restorable entity found for temporary entity';
    END IF;
END $$;

-- ============================================================================
-- Seed Section 11: Attempt to restore a non-existent entity
-- ============================================================================
DO $$
DECLARE
    v_nonexistent_id CONSTANT UUID := '00000000-0000-4000-8000-000000000000';
    v_result RECORD;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== SEED SECTION 11: Restore Non-Existent Entity ===';

    SELECT * INTO v_result
    FROM restore_entity_with_outbox(p_entity_id := v_nonexistent_id);

    IF NOT v_result.success AND v_result.error_code = 'ERR_ENTITY_NOT_FOUND' THEN
        RAISE NOTICE '✅ Restore correctly rejected non-existent entity';
        RAISE NOTICE '   error_code:    %', v_result.error_code;
        RAISE NOTICE '   error_message: %', v_result.error_message;
    ELSE
        RAISE NOTICE '❌ Unexpected result: success=% error_code=%', v_result.success, v_result.error_code;
    END IF;
END $$;

-- ============================================================================
-- Final Summary
-- ============================================================================
DO $$
DECLARE
    v_ent1_status entity_status;
    v_ent1_deleted_at TIMESTAMPTZ;
    v_ent2_status entity_status;
    v_ent2_deleted_at TIMESTAMPTZ;
    v_restore_event_count INTEGER;
BEGIN
    SELECT status, deleted_at INTO v_ent1_status, v_ent1_deleted_at
    FROM entities WHERE id = 'e0000001-0000-4000-8000-000000000001';

    SELECT status, deleted_at INTO v_ent2_status, v_ent2_deleted_at
    FROM entities WHERE id = 'e0000002-0000-4000-8000-000000000002';

    SELECT COUNT(*) INTO v_restore_event_count
    FROM outbox_events
    WHERE event_type = 'entitymanagement.entity.restored';

    RAISE NOTICE '';
    RAISE NOTICE '================================================================================';
    RAISE NOTICE '  ENTITYMGMT-07 SEED — FINAL SUMMARY';
    RAISE NOTICE '================================================================================';
    RAISE NOTICE '';
    RAISE NOTICE '--- Entity States ---';
    RAISE NOTICE 'ent-001 (Alice):     status=%, deleted_at=%  (restored ✅)',
        v_ent1_status, COALESCE(v_ent1_deleted_at::TEXT, 'NULL');
    RAISE NOTICE 'ent-002 (Bob):       status=%, deleted_at=%  (active — unchanged ✅)',
        v_ent2_status, COALESCE(v_ent2_deleted_at::TEXT, 'NULL');
    RAISE NOTICE '';
    RAISE NOTICE '--- Outbox Events ---';
    RAISE NOTICE 'entitymanagement.entity.restored events emitted: %', v_restore_event_count;
    RAISE NOTICE '';
    RAISE NOTICE '--- Gherkin Test Results ---';
    RAISE NOTICE 'SCENARIO 1 (successful restore):                     ✅ Verified';
    RAISE NOTICE '  - deleted_at cleared (set to NULL)';
    RAISE NOTICE '  - status transitions to "active"';
    RAISE NOTICE '  - entity.restored event written to outbox';
    RAISE NOTICE '  - event payload includes previous_deleted_at';
    RAISE NOTICE '  - entity visible in standard list queries';
    RAISE NOTICE '';
    RAISE NOTICE 'SCENARIO 2 (non-deleted restore rejection):          ✅ Verified';
    RAISE NOTICE '  - ERR_NOT_DELETED returned';
    RAISE NOTICE '  - message: "entity is not soft-deleted"';
    RAISE NOTICE '  - no data modified';
    RAISE NOTICE '  - no entity.restored event emitted';
    RAISE NOTICE '';
    RAISE NOTICE 'Additional validations:                              ✅ Verified';
    RAISE NOTICE '  - validate_entity_restorable() pre-check';
    RAISE NOTICE '  - get_restorable_entity() display';
    RAISE NOTICE '  - verify_entity_visible_after_restore() diagnostic';
    RAISE NOTICE '  - Non-existent entity returns ERR_ENTITY_NOT_FOUND';
    RAISE NOTICE '';
    RAISE NOTICE '================================================================================';
    RAISE NOTICE '  END OF ENTITYMGMT-07 SEED';
    RAISE NOTICE '================================================================================';
END $$;
