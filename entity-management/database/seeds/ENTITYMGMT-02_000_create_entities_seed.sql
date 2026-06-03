-- Seed: ENTITYMGMT-02_000_create_entities_seed.sql
-- Story: ENTITYMGMT-02 — User creates an entity with idempotency support (7-day TTL)
-- Bounded Context: Entity Management
--
-- This seed:
--   1. Seeds the existing "Customer" schema (from ENTITYMGMT-01) for downstream tests
--   2. Creates sample entity instances matching the Gherkin SCENARIO 1 payload
--   3. Seeds outbox_events with entitymanagement.entity.created events
--   4. Seeds request_idempotency records for SCENARIO 2 (idempotent replay)
--   5. Seeds an expired request_idempotency record for SCENARIO 3 (expired TTL)
--
-- Prerequisites:
--   - ENTITYMGMT-01 migration (entity_schemas, entity_schema_attributes, outbox_events)
--   - ENTITYMGMT-02 migration (entities, request_idempotency, helper functions)
-- ============================================================================

-- ============================================================================
-- Seed 1: Customer Schema Reference
-- The schema created by ENTITYMGMT-01 seed. We reference it for FK integrity.
-- The fixed UUID matches the seed from ENTITYMGMT-01_000_schema_definition_seed.sql:
--   'c0000001-0000-4000-8000-000000000001' = Customer schema, v1, active
-- ============================================================================
\set CUSTOMER_SCHEMA_ID 'c0000001-0000-4000-8000-000000000001'

-- ============================================================================
-- Seed 2: Entity Instances (matching Gherkin SCENARIO 1 payload)
-- Creates sample entities conforming to the Customer schema.
--
-- Gherkin payload:
--   { "schema_id": "sch-customer", "name": "Alice", "type": "customer",
--     "region": "eu-west-1",
--     "attributes": {"email": "alice@example.com", "name": "Alice"} }
--
-- Result: status="active", version=1, data_residency_zone="eu"
-- ============================================================================
WITH created_entities AS (
    INSERT INTO entities (id, schema_id, schema_version, name, type, region, status, version, attributes, metadata, created_at)
    VALUES
        -- Gherkin SCENARIO 1: Alice (eu-west-1 → data_residency_zone = 'eu')
        (
            'e1000001-0000-4000-8000-000000000001',   -- Fixed entity ID "E1" in Gherkin
            :CUSTOMER_SCHEMA_ID,
            1,
            'Alice',
            'customer',
            'eu-west-1',
            'active',
            1,
            '{"email": "alice@example.com", "name": "Alice"}'::jsonb,
            '{}'::jsonb,
            NOW() - INTERVAL '2 hours'
        ),
        -- Additional sample: Bob (us-east-1 → data_residency_zone = 'us')
        (
            'e1000001-0000-4000-8000-000000000002',
            :CUSTOMER_SCHEMA_ID,
            1,
            'Bob',
            'customer',
            'us-east-1',
            'active',
            1,
            '{"email": "bob@example.com", "name": "Bob"}'::jsonb,
            '{"source": "manual_import"}'::jsonb,
            NOW() - INTERVAL '1 hour'
        ),
        -- Additional sample: Charlie (eu-west-1, inactive status for testing)
        (
            'e1000001-0000-4000-8000-000000000003',
            :CUSTOMER_SCHEMA_ID,
            1,
            'Charlie',
            'customer',
            'eu-west-1',
            'inactive',
            1,
            '{"email": "charlie@example.com", "name": "Charlie"}'::jsonb,
            '{}'::jsonb,
            NOW() - INTERVAL '30 minutes'
        )
    RETURNING id, name, region, data_residency_zone, status, version, schema_id, attributes, metadata, created_at
)
-- ============================================================================
-- Seed 3: Event Outbox — entitymanagement.entity.created events
-- These represent the events published when entities are created.
-- Written atomically via the transactional outbox pattern within the same
-- database transaction as the entity insert (simulated here for seed data).
--
-- Event type: 'entitymanagement.entity.created' (per Gherkin SCENARIO 1)
-- Payload matches Gherkin spec exactly.
-- ============================================================================
INSERT INTO outbox_events (id, event_id, aggregate_id, aggregate_type, event_type, source, subject, payload, status, created_at)
SELECT
    gen_random_uuid()::TEXT,
    gen_random_uuid()::TEXT,
    ce.id::TEXT,
    'entity',
    'entitymanagement.entity.created',
    '/entity-manager',
    'entity/' || ce.id::TEXT,
    jsonb_build_object(
        'event_id',            gen_random_uuid()::TEXT,
        'entity_id',           ce.id::TEXT,
        'entity_name',         ce.name,
        'entity_type',         'customer',
        'region',              ce.region,
        'data_residency_zone', ce.data_residency_zone,
        'schema_id',           ce.schema_id::TEXT,
        'version',             ce.version,
        'status',              ce.status,
        'attributes',          ce.attributes,
        'metadata',            ce.metadata,
        'occurred_at',         ce.created_at
    ),
    'pending',   -- Not yet published by the outbox relay
    ce.created_at
FROM created_entities ce;

-- ============================================================================
-- Seed 4: Request Idempotency Records
-- Demonstrates the request-level idempotency pattern (Gherkin SCENARIO 1 & 2).
--
-- Gherkin SCENARIO 1: After creating entity with idempotency key
-- 'create-customer-001', the mapping is saved here. A subsequent request
-- with the same key (SCENARIO 2) will find this record and return the
-- existing entity without creating a duplicate.
-- ============================================================================
INSERT INTO request_idempotency (request_key, entity_id, expires_at, created_at)
VALUES
    -- Gherkin SCENARIO 1/2: 'create-customer-001' maps to Alice (entity "E1")
    (
        'create-customer-001',
        'e1000001-0000-4000-8000-000000000001',
        NOW() + INTERVAL '7 days',
        NOW() - INTERVAL '2 hours'
    ),
    -- Additional idempotency keys for other entities
    (
        'create-customer-002',
        'e1000001-0000-4000-8000-000000000002',
        NOW() + INTERVAL '7 days',
        NOW() - INTERVAL '1 hour'
    ),
    -- Gherkin SCENARIO 3: Expired key (stored 8 days ago, TTL of 7 days already exceeded)
    (
        'expired-key',
        'e1000001-0000-4000-8000-000000000003',
        NOW() - INTERVAL '1 day',   -- Expired 1 day ago (8 days since creation, 7 day TTL)
        NOW() - INTERVAL '8 days'
    )
ON CONFLICT (request_key) DO NOTHING;

-- ============================================================================
-- Seed 5: Verification Queries (commented — uncomment for debugging)
-- ============================================================================
-- -- Verify entities
-- SELECT id, name, region, data_residency_zone, status, version
-- FROM entities ORDER BY created_at DESC;
--
-- -- Verify idempotency keys
-- SELECT request_key, entity_id, expires_at > NOW() AS is_valid
-- FROM request_idempotency ORDER BY created_at DESC;
--
-- -- Verify SCENARIO 2: Idempotent lookup
-- SELECT * FROM get_entity_by_idempotency_key('create-customer-001');
--
-- -- Verify SCENARIO 3: Expired key returns no rows
-- SELECT * FROM get_entity_by_idempotency_key('expired-key');
--
-- -- Verify outbox events
-- SELECT event_type, subject, payload->>'entity_name' AS entity_name
-- FROM outbox_events WHERE event_type = 'entitymanagement.entity.created'
-- ORDER BY created_at DESC;
