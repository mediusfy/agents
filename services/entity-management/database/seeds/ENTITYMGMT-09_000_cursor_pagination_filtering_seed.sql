-- Seed: ENTITYMGMT-09_000_cursor_pagination_filtering_seed.sql
-- Story: ENTITYMGMT-09 — User lists entities with cursor-based pagination
--                         and multi-field filtering
-- Bounded Context: Entity Management
--
-- Gherkin precondition:
--   "Given 100 entities exist for schema 'Customer' with varied status
--    and region values"
--
-- This seed:
--   1. Seeds the "Customer" schema (if not already present from ENTITYMGMT-01)
--   2. Creates 100 sample entity instances with varied:
--      - Status values: active (70), inactive (20), deleted/soft-deleted (10)
--      - Region values: eu-west-1 (35), us-east-1 (30), us-west-2 (15),
--                       ap-southeast-1 (10), eu-central-1 (10)
--      - Names and types for realistic test data
--   3. Seeds outbox_events with entitymanagement.entity.created events
--   4. Spans created_at across a 90-day window for pagination testing
--
-- Prerequisites:
--   - ENTITYMGMT-01 migration (entity_schemas, entity_schema_attributes, outbox_events)
--   - ENTITYMGMT-02 migration (entities, request_idempotency)
--   - ENTITYMGMT-09 migration (cursor pagination functions)
-- ============================================================================

-- ============================================================================
-- Seed 1: Ensure Customer Schema Exists
-- If not already seeded from ENTITYMGMT-01, create it here.
-- ============================================================================
DO $$
DECLARE
    v_schema_id UUID;
    v_count     INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count FROM entity_schemas WHERE name = 'Customer';

    IF v_count = 0 THEN
        -- Schema doesn't exist — create it
        INSERT INTO entity_schemas (id, name, version, status, created_by)
        VALUES (
            'c0000001-0000-4000-8000-000000000001',
            'Customer',
            1,
            'active',
            'seed-entitymgmt-09'
        );

        -- Add standard attributes matching ENTITYMGMT-01 spec
        INSERT INTO entity_schema_attributes (id, schema_id, name, attr_type, required, constraints, ordinal)
        VALUES
            (gen_random_uuid(), 'c0000001-0000-4000-8000-000000000001', 'email',    'string', TRUE,  '{"pattern": "^[^@]+@[^@]+$"}', 0),
            (gen_random_uuid(), 'c0000001-0000-4000-8000-000000000001', 'age',      'int',    FALSE, '{"min": 0, "max": 150}',      1),
            (gen_random_uuid(), 'c0000001-0000-4000-8000-000000000001', 'isActive', 'bool',   FALSE, '{}',                          2),
            (gen_random_uuid(), 'c0000001-0000-4000-8000-000000000001', 'status',   'enum',   TRUE,  '{"enum": ["active", "inactive"]}', 3),
            (gen_random_uuid(), 'c0000001-0000-4000-8000-000000000001', 'metadata', 'map',    FALSE, '{}',                          4),
            (gen_random_uuid(), 'c0000001-0000-4000-8000-000000000001', 'config',   'json',   FALSE, '{}',                          5);

        RAISE NOTICE 'Created Customer schema for ENTITYMGMT-09 seed';
    END IF;
END $$;

-- ============================================================================
-- Seed 2: 100 Entity Instances with Varied Status and Region
--
-- Gherkin: "Given 100 entities exist for schema 'Customer' with varied
--           status and region values"
--
-- Distribution:
--   Status:  active = 70, inactive = 20, soft-deleted (deleted_at set) = 10
--   Region:  eu-west-1 = 35, us-east-1 = 30, us-west-2 = 15,
--            ap-southeast-1 = 10, eu-central-1 = 10
--
-- Created_at spans 90 days (most recent 90 days) for realistic pagination.
-- Each entity gets realistic customer data in attributes.
-- ============================================================================

-- Use a DO block for procedural generation
DO $$
DECLARE
    v_schema_id      CONSTANT UUID := 'c0000001-0000-4000-8000-000000000001';
    v_entity_id      UUID;
    v_name           TEXT;
    v_email          TEXT;
    v_region         TEXT;
    v_status         TEXT;
    v_age            INTEGER;
    v_is_active      BOOLEAN;
    v_created_at     TIMESTAMPTZ;
    v_deleted_at     TIMESTAMPTZ;
    v_attrs          JSONB;
    v_meta           JSONB;
    v_customer_num   INTEGER;
    v_region_idx     INTEGER;
    v_region_arr     TEXT[] := ARRAY['eu-west-1', 'eu-west-1', 'eu-west-1', 'eu-west-1', 'eu-west-1',
                                     'eu-west-1', 'eu-west-1', 'eu-west-1', 'eu-west-1', 'eu-west-1',
                                     'eu-west-1', 'eu-west-1', 'eu-west-1', 'eu-west-1', 'eu-west-1',
                                     'eu-west-1', 'eu-west-1', 'eu-west-1', 'eu-west-1', 'eu-west-1',
                                     'eu-west-1', 'eu-west-1', 'eu-west-1', 'eu-west-1', 'eu-west-1',
                                     'eu-west-1', 'eu-west-1', 'eu-west-1', 'eu-west-1', 'eu-west-1',
                                     'eu-west-1', 'eu-west-1', 'eu-west-1', 'eu-west-1', 'eu-west-1',
                                     'us-east-1', 'us-east-1', 'us-east-1', 'us-east-1', 'us-east-1',
                                     'us-east-1', 'us-east-1', 'us-east-1', 'us-east-1', 'us-east-1',
                                     'us-east-1', 'us-east-1', 'us-east-1', 'us-east-1', 'us-east-1',
                                     'us-east-1', 'us-east-1', 'us-east-1', 'us-east-1', 'us-east-1',
                                     'us-east-1', 'us-east-1', 'us-east-1', 'us-east-1', 'us-east-1',
                                     'us-east-1', 'us-east-1', 'us-east-1', 'us-east-1', 'us-east-1',
                                     'us-west-2', 'us-west-2', 'us-west-2', 'us-west-2', 'us-west-2',
                                     'us-west-2', 'us-west-2', 'us-west-2', 'us-west-2', 'us-west-2',
                                     'us-west-2', 'us-west-2', 'us-west-2', 'us-west-2', 'us-west-2',
                                     'ap-southeast-1', 'ap-southeast-1', 'ap-southeast-1', 'ap-southeast-1', 'ap-southeast-1',
                                     'ap-southeast-1', 'ap-southeast-1', 'ap-southeast-1', 'ap-southeast-1', 'ap-southeast-1',
                                     'eu-central-1', 'eu-central-1', 'eu-central-1', 'eu-central-1', 'eu-central-1',
                                     'eu-central-1', 'eu-central-1', 'eu-central-1', 'eu-central-1', 'eu-central-1'];
    v_first_names    TEXT[] := ARRAY['Alice', 'Bob', 'Charlie', 'Diana', 'Eve', 'Frank', 'Grace', 'Henry', 'Iris', 'Jack',
                                     'Kate', 'Liam', 'Mia', 'Noah', 'Olivia', 'Paul', 'Quinn', 'Rose', 'Sam', 'Tina',
                                     'Uma', 'Victor', 'Wendy', 'Xavier', 'Yara', 'Zack', 'Aaron', 'Bella', 'Carter', 'Daisy',
                                     'Ethan', 'Fiona', 'George', 'Hannah', 'Isaac', 'Julia', 'Kevin', 'Luna', 'Mason', 'Nina',
                                     'Oscar', 'Piper', 'Riley', 'Sofia', 'Thomas', 'Uma', 'Violet', 'William', 'Xena', 'Yuki',
                                     'Amber', 'Blake', 'Chloe', 'Derek', 'Eliza', 'Felix', 'Gia', 'Hunter', 'Isla', 'Jade',
                                     'Kai', 'Lena', 'Marco', 'Nora', 'Owen', 'Paige', 'Rafael', 'Sage', 'Troy', 'Uma',
                                     'Vince', 'Wade', 'Xia', 'Yuri', 'Zara', 'Adam', 'Brooke', 'Cole', 'Demi', 'Eli',
                                     'Faith', 'Gavin', 'Hazel', 'Ivan', 'Jade', 'Kyle', 'Leah', 'Miles', 'Nadia', 'Orion',
                                     'Preston', 'Rhea', 'Shane', 'Talia', 'Ulrich', 'Vera', 'Wren', 'Yael', 'Zion', 'Ashton'];
    v_last_names     TEXT[] := ARRAY['Smith', 'Johnson', 'Williams', 'Brown', 'Jones', 'Garcia', 'Miller', 'Davis',
                                      'Rodriguez', 'Martinez', 'Hernandez', 'Lopez', 'Gonzalez', 'Wilson', 'Anderson',
                                      'Thomas', 'Taylor', 'Moore', 'Jackson', 'Martin', 'Lee', 'Perez', 'Thompson',
                                      'White', 'Harris', 'Sanchez', 'Clark', 'Ramirez', 'Lewis', 'Robinson',
                                      'Walker', 'Young', 'Allen', 'King', 'Wright', 'Scott', 'Torres', 'Nguyen',
                                      'Hill', 'Flores', 'Green', 'Adams', 'Nelson', 'Baker', 'Hall', 'Rivera',
                                      'Campbell', 'Mitchell', 'Carter', 'Roberts'];
    v_status_arr     TEXT[];
    v_tier_arr       TEXT[] := ARRAY['basic', 'premium', 'enterprise', 'gold', 'platinum'];
    v_tier           TEXT;
    v_signed_up_days INTEGER;
BEGIN
    -- Build the status array: 70 active, 20 inactive, 10 deleted
    v_status_arr := ARRAY(SELECT 'active' FROM generate_series(1, 70))
                    || ARRAY(SELECT 'inactive' FROM generate_series(1, 20))
                    || ARRAY(SELECT 'deleted' FROM generate_series(1, 10));

    -- Generate 100 entities
    FOR v_customer_num IN 0..99 LOOP
        -- Generate a deterministic UUID for reproducibility
        v_entity_id := ('e2000000-0000-4000-8000-' || LPAD(to_hex(v_customer_num), 12, '0'))::UUID;

        v_name := v_first_names[1 + (v_customer_num % 100)] || ' ' || v_last_names[1 + (v_customer_num % 50)];
        v_email := lower(v_first_names[1 + (v_customer_num % 100)]) || '.' || lower(v_last_names[1 + (v_customer_num % 50)]) || '@example.com';
        v_region := v_region_arr[1 + v_customer_num];
        v_status := v_status_arr[1 + v_customer_num];
        v_age := 18 + (v_customer_num % 60);
        v_is_active := (v_status = 'active');
        v_tier := v_tier_arr[1 + (v_customer_num % 5)];

        -- Stagger created_at across 90 days (most recent entities first)
        -- Entities with higher indices are created later (more recent)
        v_created_at := NOW() - INTERVAL '90 days' + (v_customer_num * INTERVAL '21 hours 36 minutes');

        -- Deleted entities get deleted_at set (10-30 days after creation)
        v_deleted_at := CASE
            WHEN v_status = 'deleted' THEN v_created_at + INTERVAL '10 days' + (v_customer_num % 20) * INTERVAL '1 day'
            ELSE NULL
        END;

        -- Build attributes JSONB
        v_attrs := jsonb_build_object(
            'email',    v_email,
            'name',     v_name,
            'age',      v_age,
            'isActive', v_is_active,
            'tier',     v_tier,
            'signed_up_days', v_customer_num + 1
        );

        -- Build metadata JSONB
        v_meta := jsonb_build_object(
            'source',       CASE WHEN v_customer_num < 30 THEN 'manual_import' ELSE 'api' END,
            'import_batch', 'seed-entitymgmt-09',
            'customer_num', v_customer_num + 1
        );

        -- Insert the entity
        INSERT INTO entities (
            id, schema_id, schema_version, name, type, region,
            status, version, attributes, metadata,
            created_at, updated_at, deleted_at
        ) VALUES (
            v_entity_id, v_schema_id, 1, v_name, 'customer', v_region,
            v_status::entity_status, 1, v_attrs, v_meta,
            v_created_at, v_created_at, v_deleted_at
        )
        ON CONFLICT (id) DO UPDATE SET
            name = EXCLUDED.name,
            status = EXCLUDED.status,
            region = EXCLUDED.region,
            attributes = EXCLUDED.attributes,
            metadata = EXCLUDED.metadata,
            deleted_at = EXCLUDED.deleted_at;
    END LOOP;

    RAISE NOTICE 'Seeded 100 entities for Customer schema with varied status and region values';
    RAISE NOTICE '  - Status: 70 active, 20 inactive, 10 deleted (soft-deleted)';
    RAISE NOTICE '  - Region: 35 eu-west-1, 30 us-east-1, 15 us-west-2, 10 ap-southeast-1, 10 eu-central-1';
    RAISE NOTICE '  - Created_at spans 90 days for pagination testing';
END $$;

-- ============================================================================
-- Seed 3: Outbox events for entity.created
-- ============================================================================
INSERT INTO outbox_events (id, event_id, aggregate_id, aggregate_type, event_type, source, subject, payload, status, created_at)
SELECT
    gen_random_uuid()::TEXT,
    gen_random_uuid()::TEXT,
    e.id::TEXT,
    'entity',
    'entitymanagement.entity.created',
    '/entity-manager',
    'entity/' || e.id::TEXT,
    jsonb_build_object(
        'event_id',            gen_random_uuid()::TEXT,
        'entity_id',           e.id::TEXT,
        'entity_name',         e.name,
        'entity_type',         'customer',
        'region',              e.region,
        'data_residency_zone', e.data_residency_zone,
        'schema_id',           e.schema_id::TEXT,
        'version',             e.version,
        'status',              e.status,
        'attributes',          e.attributes,
        'metadata',            e.metadata,
        'occurred_at',         e.created_at
    ),
    'published',   -- Mark as published for seed data to avoid outbox relay re-publishing
    e.created_at
FROM entities e
WHERE e.schema_id = 'c0000001-0000-4000-8000-000000000001'
  AND NOT EXISTS (
    SELECT 1 FROM outbox_events o
    WHERE o.aggregate_id = e.id::TEXT
      AND o.event_type = 'entitymanagement.entity.created'
  );

-- ============================================================================
-- Seed 4: Verification (commented — uncomment to run checks)
-- ============================================================================
-- -- Verify entity counts
-- SELECT status, region, COUNT(*) as cnt
-- FROM entities
-- WHERE schema_id = 'c0000001-0000-4000-8000-000000000001'
-- GROUP BY GROUPING SETS ((status), (region), ())
-- ORDER BY status, region;
--
-- -- Verify cursor pagination
-- SELECT * FROM verify_cursor_pagination();
--
-- -- Test first page
-- SELECT count(*) as page_count FROM list_entities_cursor(
--   'c0000001-0000-4000-8000-000000000001'::TEXT,
--   20, NULL, ARRAY[]::TEXT[], FALSE
-- );
--
-- -- Test filtered query
-- SELECT encode_cursor_token(created_at, entity_id) as cursor_token
-- FROM list_entities_cursor(
--   'c0000001-0000-4000-8000-000000000001'::TEXT,
--   20, NULL, ARRAY['status==active', 'region~eu'], FALSE
-- ) LIMIT 1;

-- ============================================================================
-- Seed 5: Summary
-- ============================================================================
DO $$
DECLARE
    v_total   BIGINT;
    v_active  BIGINT;
    v_inactive BIGINT;
    v_deleted BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_total
    FROM entities WHERE schema_id = 'c0000001-0000-4000-8000-000000000001';

    SELECT COUNT(*) INTO v_active
    FROM entities WHERE schema_id = 'c0000001-0000-4000-8000-000000000001' AND status = 'active';

    SELECT COUNT(*) INTO v_inactive
    FROM entities WHERE schema_id = 'c0000001-0000-4000-8000-000000000001' AND status = 'inactive';

    SELECT COUNT(*) INTO v_deleted
    FROM entities WHERE schema_id = 'c0000001-0000-4000-8000-000000000001' AND status = 'deleted';

    RAISE NOTICE '============================================';
    RAISE NOTICE 'ENTITYMGMT-09 Seed Summary:';
    RAISE NOTICE '  Total entities:        %', v_total;
    RAISE NOTICE '  Active:                %', v_active;
    RAISE NOTICE '  Inactive:              %', v_inactive;
    RAISE NOTICE '  Soft-deleted:          %', v_deleted;
    RAISE NOTICE '  Regions: eu-west-1, us-east-1, us-west-2, ap-southeast-1, eu-central-1';
    RAISE NOTICE '  Created_at: 90-day window for pagination';
    RAISE NOTICE '============================================';
END $$;
