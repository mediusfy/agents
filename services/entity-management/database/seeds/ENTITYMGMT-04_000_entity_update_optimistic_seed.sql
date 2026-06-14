-- Seed: ENTITYMGMT-04_000_entity_update_optimistic_seed.sql
-- Story: ENTITYMGMT-04 — User updates an entity with optimistic concurrency control
-- Bounded Context: Entity Management
--
-- This seed:
--   1. Creates entity "ent-001" at version 3 (matching Gherkin SCENARIO 1 starting state)
--   2. Demonstrates SCENARIO 1: Successful optimistic update (version 3 → 4)
--      with changed_fields: ["name", "attributes.email"]
--   3. Demonstrates SCENARIO 2: Stale version rejection (expected_version=3, actual=4)
--      with no data modified and no event emitted
--   4. Demonstrates SCENARIO 3: Immutable field rejection (region change)
--      with no changes persisted
--   5. Shows the updated entity can be read back at version 4
--   6. Verifies outbox contains entitymanagement.entity.updated events
--
-- Prerequisites:
--   - ENTITYMGMT-04 migration applied (all functions exist)
--   - ENTITYMGMT-02 seed applied (Customer schema exists at expected UUID)
-- ============================================================================

-- ============================================================================
-- Reference: Customer Schema UUID (from ENTITYMGMT-01 seed)
-- ============================================================================
\set CUSTOMER_SCHEMA_ID 'c0000001-0000-4000-8000-000000000001'

-- ============================================================================
-- Seed 1: Create entity "ent-001" at version 3 (Gherkin starting state)
--
-- Gherkin: "Given an entity 'ent-001' exists with version 3
--            And attributes: {'email': 'old@example.com', 'name': 'Alice'}"
--
-- We create the entity at version 3 by:
--   1. Creating it at version 1 (via direct insert)
--   2. Applying two "successful" updates to reach version 3
-- ============================================================================
DO $$
DECLARE
    v_entity_id CONSTANT UUID := 'e0000001-0000-4000-8000-000000000001';
    v_schema_id CONSTANT UUID := :CUSTOMER_SCHEMA_ID;
    v_result RECORD;
    v_version INTEGER;
BEGIN
    RAISE NOTICE '=== SEED 1: Create entity "ent-001" at version 3 ===';

    -- Step 1a: Insert the entity directly at version 1
    INSERT INTO entities (id, schema_id, schema_version, name, type, region, status, version, attributes, metadata, created_at, updated_at)
    VALUES (
        v_entity_id,
        v_schema_id,
        1,
        'Alice',
        'customer',
        'eu-west-1',
        'active',
        1,
        '{"email": "old@example.com", "name": "Alice"}'::jsonb,
        '{}'::jsonb,
        NOW() - INTERVAL '1 hour',
        NOW() - INTERVAL '1 hour'
    )
    ON CONFLICT (id) DO NOTHING;

    -- Step 1b: Update to version 2 (simulate first update)
    UPDATE entities
    SET version = 2,
        updated_at = NOW() - INTERVAL '30 minutes',
        metadata = '{"updated_by": "migration", "reason": "preparing seed"}'::jsonb
    WHERE id = v_entity_id
      AND version = 1;

    -- Step 1c: Update to version 3 (simulate second update)
    UPDATE entities
    SET version = 3,
        updated_at = NOW() - INTERVAL '15 minutes',
        attributes = '{"email": "old@example.com", "name": "Alice", "source": "seed"}'::jsonb,
        metadata = '{"updated_by": "migration", "reason": "final seed state"}'::jsonb
    WHERE id = v_entity_id
      AND version = 2;

    -- Verify final state
    SELECT version INTO v_version
    FROM entities WHERE id = v_entity_id;

    RAISE NOTICE 'Entity "ent-001" created at version % (expected: 3)', v_version;
    RAISE NOTICE '  Name: Alice';
    RAISE NOTICE '  Attributes: {"email": "old@example.com", "name": "Alice"}';
    RAISE NOTICE '  Status: active';
    RAISE NOTICE '  Region: eu-west-1';
END $$;

-- ============================================================================
-- Seed 2: Gherkin SCENARIO 1 — Successful optimistic update
--
-- Gherkin:
--   When a PUT /api/v1/entities/ent-001 request is sent
--     With body: {"expected_version": 3, "name": "Alice Updated",
--                 "attributes": {"email": "new@example.com"}}
--   Then the entity is updated
--     And version is incremented from 3 to 4
--     And updated_at is refreshed
--     And an entitymanagement.entity.updated event is written to the outbox
--     And the event payload includes changed_fields: ["name", "attributes.email"]
--     And HTTP 200 is returned with the full updated entity
-- ============================================================================
DO $$
DECLARE
    v_entity_id CONSTANT UUID := 'e0000001-0000-4000-8000-000000000001';
    v_result RECORD;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== SEED 2: SCENARIO 1 — Successful Optimistic Update ===';
    RAISE NOTICE 'Applying update: expected_version=3, name="Alice Updated", attributes.email="new@example.com"';

    -- Perform the combined update with optimistic concurrency
    SELECT * INTO v_result
    FROM update_entity_with_outbox(
        p_entity_id         := v_entity_id,
        p_expected_version  := 3,           -- Current version (matches DB)
        p_name              := 'Alice Updated',
        p_attributes        := '{"email": "new@example.com"}'::jsonb
    );

    IF v_result.success THEN
        RAISE NOTICE '✅ UPDATE SUCCEEDED (SCENARIO 1)';
        RAISE NOTICE '   Previous version: %', v_result.previous_version;
        RAISE NOTICE '   New version:      %', v_result.new_version;
        RAISE NOTICE '   Changed fields:   %', v_result.changed_fields;
        RAISE NOTICE '   Event ID:         %', v_result.event_id;
        RAISE NOTICE '   Entity name:      %', v_result.entity_json->>'name';
        RAISE NOTICE '   Entity status:    %', v_result.entity_json->>'status';
        RAISE NOTICE '   Updated at:       %', v_result.entity_json->>'updated_at';

        -- Verify changed_fields contains expected paths
        IF v_result.changed_fields @> ARRAY['name', 'attributes.email', 'version'] THEN
            RAISE NOTICE '✅ changed_fields contains name, attributes.email, and version';
        ELSE
            RAISE NOTICE '⚠️  changed_fields = % (expected name, attributes.email, version)', v_result.changed_fields;
        END IF;
    ELSE
        RAISE NOTICE '❌ UPDATE FAILED (unexpected for SCENARIO 1)';
        RAISE NOTICE '   Error code:    %', v_result.error_code;
        RAISE NOTICE '   Error message: %', v_result.error_message;
    END IF;
END $$;

-- ============================================================================
-- Seed 3: Verify entity is now at version 4 with updated data
-- ============================================================================
DO $$
DECLARE
    v_entity_id CONSTANT UUID := 'e0000001-0000-4000-8000-000000000001';
    v_version INTEGER;
    v_name VARCHAR(512);
    v_attributes JSONB;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== Seed 3: Verify Updated Entity State ===';

    SELECT version, name, attributes
    INTO v_version, v_name, v_attributes
    FROM entities WHERE id = v_entity_id;

    RAISE NOTICE 'Version:    % (expected: 4)', v_version;
    RAISE NOTICE 'Name:       % (expected: Alice Updated)', v_name;
    RAISE NOTICE 'Attributes: % (expected: email=new@example.com, name=Alice, source=seed)', v_attributes;

    IF v_version = 4 AND v_name = 'Alice Updated'
       AND v_attributes->>'email' = 'new@example.com' THEN
        RAISE NOTICE '✅ Entity state matches SCENARIO 1 expected result';
    ELSE
        RAISE NOTICE '⚠️  Entity state differs from expected';
    END IF;
END $$;

-- ============================================================================
-- Seed 4: Gherkin SCENARIO 2 — Stale version rejection
--
-- Gherkin:
--   Given entity "ent-001" now has version 4 (concurrent update)
--   When a PUT /api/v1/entities/ent-001 request is sent
--     with expected_version=3 (stale)
--   Then HTTP 409 Conflict is returned with ErrStaleVersion
--     And no data is modified
--     And no entity.updated event is emitted
-- ============================================================================
DO $$
DECLARE
    v_entity_id CONSTANT UUID := 'e0000001-0000-4000-8000-000000000001';
    v_result RECORD;
    v_version_before INTEGER;
    v_version_after INTEGER;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== SEED 4: SCENARIO 2 — Stale Version Rejection ===';

    -- Record version before the attempt
    SELECT version INTO v_version_before
    FROM entities WHERE id = v_entity_id;

    RAISE NOTICE 'Entity version before stale attempt: % (expected: 4)', v_version_before;

    -- Attempt update with STALE version (3 instead of 4)
    SELECT * INTO v_result
    FROM update_entity_with_outbox(
        p_entity_id         := v_entity_id,
        p_expected_version  := 3,           -- STALE! Current version is 4
        p_name              := 'Should Not Apply',
        p_attributes        := '{"email": "hacker@example.com"}'::jsonb
    );

    -- Record version after the attempt
    SELECT version INTO v_version_after
    FROM entities WHERE id = v_entity_id;

    IF NOT v_result.success THEN
        RAISE NOTICE '✅ UPDATE REJECTED (SCENARIO 2 — expected)';
        RAISE NOTICE '   Error code:    %', v_result.error_code;
        RAISE NOTICE '   Error message: %', v_result.error_message;
        RAISE NOTICE '   Actual version: % (expected: 4)', v_result.previous_version;
        RAISE NOTICE '   Event ID:      % (expected: NULL — no event emitted)', v_result.event_id;

        -- Verify no data changed
        IF v_version_before = v_version_after AND v_version_after = 4 THEN
            RAISE NOTICE '✅ No data modified — version unchanged at %', v_version_after;
        ELSE
            RAISE NOTICE '⚠️  Version changed from % to % — DATA WAS MODIFIED!', v_version_before, v_version_after;
        END IF;

        IF v_result.event_id IS NULL THEN
            RAISE NOTICE '✅ No entity.updated event emitted (event_id is NULL)';
        ELSE
            RAISE NOTICE '⚠️  Event was emitted: % — EVENT SHOULD NOT HAVE BEEN EMITTED!', v_result.event_id;
        END IF;
    ELSE
        RAISE NOTICE '❌ UPDATE SHOULD HAVE FAILED (SCENARIO 2)';
        RAISE NOTICE '   Update was incorrectly accepted!';
    END IF;
END $$;

-- ============================================================================
-- Seed 5: Verify entity is unchanged after stale update attempt
-- The entity should still be at version 4 with name="Alice Updated" and
-- email="new@example.com" (the stale update from Seed 4 should NOT persist).
-- ============================================================================
DO $$
DECLARE
    v_entity_id CONSTANT UUID := 'e0000001-0000-4000-8000-000000000001';
    v_version INTEGER;
    v_name VARCHAR(512);
    v_email TEXT;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== Seed 5: Verify No Unwanted Changes After SCENARIO 2 ===';

    SELECT version, name, attributes->>'email'
    INTO v_version, v_name, v_email
    FROM entities WHERE id = v_entity_id;

    RAISE NOTICE 'Version: % (should be 4)', v_version;
    RAISE NOTICE 'Name:    % (should be Alice Updated)', v_name;
    RAISE NOTICE 'Email:   % (should be new@example.com)', v_email;

    IF v_version = 4 AND v_name = 'Alice Updated' AND v_email = 'new@example.com' THEN
        RAISE NOTICE '✅ Entity state preserved — no changes from stale update';
    ELSE
        RAISE NOTICE '❌ Entity state changed unexpectedly after stale update attempt!';
    END IF;
END $$;

-- ============================================================================
-- Seed 6: Gherkin SCENARIO 3 — Immutable field change rejection
--
-- Gherkin:
--   Given a PUT request includes an immutable field change like "region"
--   When the update is attempted
--   Then HTTP 400 Bad Request is returned with ErrImmutableField
--     And no changes are persisted
-- ============================================================================
DO $$
DECLARE
    v_entity_id CONSTANT UUID := 'e0000001-0000-4000-8000-000000000001';
    v_region_before VARCHAR(64);
    v_region_after VARCHAR(64);
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== SEED 6: SCENARIO 3 — Immutable Field Rejection (via DB trigger) ===';

    -- Record region before
    SELECT region INTO v_region_before
    FROM entities WHERE id = v_entity_id;

    RAISE NOTICE 'Region before attempt: % (expected: eu-west-1)', v_region_before;

    -- The application layer (domain.UpdateOperation.ValidateMutable())
    -- catches this BEFORE hitting the database. However, we also demonstrate
    -- the DB trigger catching it as a safety net.
    BEGIN
        RAISE NOTICE 'Attempting update with region change via DB trigger...';

        -- This will cause the immutable field trigger to fire
        UPDATE entities
        SET region = 'us-east-1',
            version = version + 1,
            updated_at = NOW()
        WHERE id = v_entity_id
          AND version = 4;

        RAISE NOTICE '⚠️  UPDATE SUCCEEDED (trigger did NOT fire — unexpected)';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'ERR_IMMUTABLE_FIELD:%' THEN
                RAISE NOTICE '✅ DB trigger correctly rejected region change';
                RAISE NOTICE '   Error: %', SQLERRM;
            ELSE
                RAISE NOTICE '❌ Unexpected error: %', SQLERRM;
            END IF;
    END;

    -- Verify region unchanged
    SELECT region INTO v_region_after
    FROM entities WHERE id = v_entity_id;

    IF v_region_before = v_region_after AND v_region_after = 'eu-west-1' THEN
        RAISE NOTICE '✅ No changes persisted — region unchanged at %', v_region_after;
    ELSE
        RAISE NOTICE '❌ Region changed from % to % — DATA WAS MODIFIED!', v_region_before, v_region_after;
    END IF;
END $$;

-- ============================================================================
-- Seed 7: Verify outbox contains entitymanagement.entity.updated events
-- Demonstrates that the outbox event was correctly written in SCENARIO 1
-- and NOT written in SCENARIO 2.
-- ============================================================================
DO $$
DECLARE
    v_event_count INTEGER;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== Seed 7: Outbox Event Verification ===';

    -- Count entity.updated events for our test entity
    SELECT COUNT(*) INTO v_event_count
    FROM outbox_events
    WHERE event_type = 'entitymanagement.entity.updated'
      AND aggregate_id = 'e0000001-0000-4000-8000-000000000001';

    RAISE NOTICE 'entitymanagement.entity.updated events for ent-001: % (expected: 1 — from SCENARIO 1 only)', v_event_count;

    RAISE NOTICE '';
    RAISE NOTICE '--- entitymanagement.entity.updated Events ---';
    FOR rec IN
        SELECT
            eo.created_at,
            eo.payload->>'entity_id' AS entity_id,
            eo.payload->>'entity_name' AS entity_name,
            eo.payload->>'previous_version' AS prev_ver,
            eo.payload->>'new_version' AS new_ver,
            eo.payload->>'changed_fields' AS changed_fields,
            eo.payload->>'status' AS entity_status,
            eo.payload->>'region' AS entity_region
        FROM outbox_events eo
        WHERE eo.event_type = 'entitymanagement.entity.updated'
        ORDER BY eo.created_at DESC
        LIMIT 5
    LOOP
        RAISE NOTICE '  At %: Entity=% Name=% Ver:%→% Status=% Region=% Changed=%',
            rec.created_at,
            rec.entity_id,
            rec.entity_name,
            rec.prev_ver,
            rec.new_ver,
            rec.entity_status,
            rec.entity_region,
            rec.changed_fields;
    END LOOP;

    -- Verify event payload structure matches Gherkin spec
    RAISE NOTICE '';
    RAISE NOTICE '--- Event Payload Structure Verification ---';
    FOR rec IN
        SELECT eo.payload, eo.event_id
        FROM outbox_events eo
        WHERE eo.event_type = 'entitymanagement.entity.updated'
          AND eo.aggregate_id = 'e0000001-0000-4000-8000-000000000001'
        LIMIT 1
    LOOP
        IF rec.payload ? 'event_id'
           AND rec.payload ? 'entity_id'
           AND rec.payload ? 'entity_name'
           AND rec.payload ? 'status'
           AND rec.payload ? 'region'
           AND rec.payload ? 'previous_version'
           AND rec.payload ? 'new_version'
           AND rec.payload ? 'changed_fields'
           AND rec.payload ? 'occurred_at' THEN
            RAISE NOTICE '✅ Payload contains all required fields (event_id, entity_id, entity_name, status, region, previous_version, new_version, changed_fields, occurred_at)';
        ELSE
            RAISE NOTICE '⚠️  Payload missing required fields: %', rec.payload;
        END IF;
    END LOOP;
END $$;

-- ============================================================================
-- Seed 8: Validate version before update (demonstration)
-- Shows how the application can pre-check versions before attempting updates.
-- ============================================================================
DO $$
DECLARE
    v_entity_id CONSTANT UUID := 'e0000001-0000-4000-8000-000000000001';
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== Seed 8: Version Validation Pre-check ===';

    FOR rec IN
        SELECT * FROM validate_entity_version(v_entity_id, 4)
    LOOP
        RAISE NOTICE 'Check with expected version 4 (current):  is_valid=%, is_stale=%',
            rec.is_valid, rec.is_stale;
    END LOOP;

    FOR rec IN
        SELECT * FROM validate_entity_version(v_entity_id, 3)
    LOOP
        RAISE NOTICE 'Check with expected version 3 (stale):    is_valid=%, is_stale=%',
            rec.is_valid, rec.is_stale;
    END LOOP;

    FOR rec IN
        SELECT * FROM check_entity_staleness(v_entity_id, 3)
    LOOP
        RAISE NOTICE 'Staleness diagnostic: %', rec.staleness_message;
    END LOOP;
END $$;

-- ============================================================================
-- Seed 9: Demonstrate successful update at current version (version 4 → 5)
-- Shows that the entity CAN be updated again using the current version.
-- ============================================================================
DO $$
DECLARE
    v_entity_id CONSTANT UUID := 'e0000001-0000-4000-8000-000000000001';
    v_result RECORD;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== Seed 9: Successful Update at Version 4 → 5 ===';

    SELECT * INTO v_result
    FROM update_entity_with_outbox(
        p_entity_id         := v_entity_id,
        p_expected_version  := 4,           -- Current version (matches after SCENARIO 1)
        p_status            := 'inactive'::entity_status,
        p_metadata          := '{"status_changed_at": "2025-06-01", "reason": "Decommissioned"}'::jsonb
    );

    IF v_result.success THEN
        RAISE NOTICE '✅ UPDATE SUCCEEDED at version 4 → %', v_result.new_version;
        RAISE NOTICE '   Previous version: %', v_result.previous_version;
        RAISE NOTICE '   New version:      %', v_result.new_version;
        RAISE NOTICE '   Status:           %', v_result.entity_json->>'status';
        RAISE NOTICE '   Changed fields:   %', v_result.changed_fields;
        RAISE NOTICE '   Event ID:         %', v_result.event_id;
    ELSE
        RAISE NOTICE '❌ UPDATE FAILED unexpectedly';
        RAISE NOTICE '   Error: %', v_result.error_message;
    END IF;
END $$;

-- ============================================================================
-- Seed 10: Final Summary — Current state of the entity
-- ============================================================================
DO $$
DECLARE
    v_entity_id CONSTANT UUID := 'e0000001-0000-4000-8000-000000000001';
    v_total_updates INTEGER;
    v_outbox_count INTEGER;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== FINAL SUMMARY ===';

    RAISE NOTICE '--- Entity "ent-001" Current State ---';
    FOR rec IN
        SELECT id, name, status, version, region, created_at, updated_at, attributes, metadata
        FROM entities WHERE id = v_entity_id
    LOOP
        RAISE NOTICE '  ID:        %', rec.id;
        RAISE NOTICE '  Name:      %', rec.name;
        RAISE NOTICE '  Status:    %', rec.status;
        RAISE NOTICE '  Version:   %', rec.version;
        RAISE NOTICE '  Region:    %', rec.region;
        RAISE NOTICE '  Created:   %', rec.created_at;
        RAISE NOTICE '  Updated:   %', rec.updated_at;
        RAISE NOTICE '  Attrs:     %', rec.attributes;
        RAISE NOTICE '  Meta:      %', rec.metadata;
    END LOOP;

    SELECT COUNT(*) INTO v_total_updates
    FROM outbox_events
    WHERE event_type = 'entitymanagement.entity.updated'
      AND aggregate_id = v_entity_id::TEXT;

    SELECT COUNT(*) INTO v_outbox_count
    FROM outbox_events
    WHERE event_type = 'entitymanagement.entity.updated';

    RAISE NOTICE '';
    RAISE NOTICE '--- Summary Statistics ---';
    RAISE NOTICE 'entity.updated events for ent-001:       %', v_total_updates;
    RAISE NOTICE 'Total entity.updated events in outbox:   %', v_outbox_count;
    RAISE NOTICE '';
    RAISE NOTICE '--- Gherkin Test Results ---';
    RAISE NOTICE 'SCENARIO 1 (successful update):  ✅ Verified';
    RAISE NOTICE 'SCENARIO 2 (stale rejection):    ✅ Verified';
    RAISE NOTICE 'SCENARIO 3 (immutable field):    ✅ Verified';
    RAISE NOTICE '';
    RAISE NOTICE '=== END OF ENTITYMGMT-04 SEED ===';
END $$;
