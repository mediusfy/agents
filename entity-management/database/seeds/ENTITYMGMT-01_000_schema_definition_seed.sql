-- Seed: ENTITYMGMT-01_000_schema_definition_seed.sql
-- Story: ENTITYMGMT-01 — Admin defines "Customer" entity schema with typed attributes
-- Bounded Context: Entity Management
--
-- This seed:
--   1. Defines the "Customer" entity schema with all 6 supported attribute types
--      (string, int, bool, enum, map, json) matching the Gherkin table exactly
--   2. Seeds the event_outbox with an entitymanagement.schema.defined event
--   3. Provides a pre-seeded schema for downstream integration tests
--
-- Gherkin reference:
--   | name     | type   | required | constraint          |
--   | email    | string | true     | pattern=^[^@]+@[^@]+$ |
--   | age      | int    | false    | min=0 max=150       |
--   | isActive | bool   | false    |                     |
--   | status   | enum   | true     | enum=[active,inactive] |
--   | metadata | map    | false    |                     |
--   | config   | json   | false    |                     |
--
-- Prerequisites:
--   - ENTITYMGMT-01 migration (entity_schemas, entity_schema_attributes, outbox_events)
-- ============================================================================

-- ============================================================================
-- Seed 1: Customer Schema (v1)
-- The schema referenced by the Gherkin "Given the system is initialized
-- with empty schema registry" → "When an admin defines an entity schema
-- named 'Customer'".
--
-- Uses a fixed UUID for reproducibility in integration tests.
-- ============================================================================
WITH schema_insert AS (
    INSERT INTO entity_schemas (id, name, version, status, created_by, created_at, updated_at)
    VALUES (
        'c0000001-0000-4000-8000-000000000001',  -- Fixed schema ID for reproducibility
        'Customer',
        1,
        'active',
        'admin@example.com',
        NOW() - INTERVAL '1 day',
        NOW() - INTERVAL '1 day'
    )
    RETURNING id
)
INSERT INTO entity_schema_attributes (id, schema_id, name, attr_type, required, constraints, ordinal, created_at)
SELECT
    gen_random_uuid(), id, 'email',    'string', TRUE,  '{"pattern": "^[^@]+@[^@]+$"}',                   0, NOW() - INTERVAL '1 day'
FROM schema_insert
UNION ALL
SELECT
    gen_random_uuid(), id, 'age',      'int',    FALSE, '{"min": 0, "max": 150}',                          1, NOW() - INTERVAL '1 day'
FROM schema_insert
UNION ALL
SELECT
    gen_random_uuid(), id, 'isActive', 'bool',   FALSE, '{}',                                              2, NOW() - INTERVAL '1 day'
FROM schema_insert
UNION ALL
SELECT
    gen_random_uuid(), id, 'status',   'enum',   TRUE,  '{"enum": ["active", "inactive"]}',                3, NOW() - INTERVAL '1 day'
FROM schema_insert
UNION ALL
SELECT
    gen_random_uuid(), id, 'metadata', 'map',    FALSE, '{}',                                              4, NOW() - INTERVAL '1 day'
FROM schema_insert
UNION ALL
SELECT
    gen_random_uuid(), id, 'config',   'json',   FALSE, '{}',                                              5, NOW() - INTERVAL '1 day'
FROM schema_insert;

-- ============================================================================
-- Seed 2: emqueue the entitymanagement.schema.defined CloudEvent
-- This is the event that the Gherkin requires: "an entitymanagement.schema.defined
-- CloudEvent is written to the transactional outbox".
--
-- The event is marked as already published (status = 'published') for seed data
-- to avoid the outbox relay from re-publishing it in test environments.
-- ============================================================================
SELECT enqueue_schema_defined_event(
    p_schema_id   := 'c0000001-0000-4000-8000-000000000001',
    p_schema_name := 'Customer',
    p_version     := 1,
    p_created_by  := 'admin@example.com'
);

-- ============================================================================
-- Seed 3: Verify the seed with a query (commented — uncomment for debugging)
-- ============================================================================
-- SELECT * FROM get_schema_with_attributes('c0000001-0000-4000-8000-000000000001');
-- SELECT * FROM find_schema_by_name('Customer');
-- SELECT * FROM outbox_events WHERE event_type = 'entitymanagement.schema.defined' ORDER BY created_at DESC LIMIT 1;
