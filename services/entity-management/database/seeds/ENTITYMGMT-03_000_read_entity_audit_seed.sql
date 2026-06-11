-- Seed: ENTITYMGMT-03_000_read_entity_audit_seed.sql
-- Story: ENTITYMGMT-03 — User retrieves an entity by ID with observability event
-- Bounded Context: Entity Management
--
-- This seed:
--   1. References existing entities from ENTITYMGMT-02 seed
--   2. Seeds sample entity_read_audit_log entries demonstrating SCENARIO 1 & 2
--   3. Seeds outbox_events with entitymanagement.entity.read events
--   4. Provides test data for ObservabilityContext (latency metrics, access audit)
--      and ResidencyContext (cross-region read tracking)
--
-- Prerequisites:
--   - ENTITYMGMT-01 migration (entity_schemas, entity_schema_attributes, outbox_events)
--   - ENTITYMGMT-02 migration (entities, request_idempotency, entity_status ENUM)
--   - ENTITYMGMT-03 migration (entity_read_audit_log, helper functions)
--   - ENTITYMGMT-02 seed (sample entities: Alice, Bob, Charlie)
-- ============================================================================

-- ============================================================================
-- Entity References (from ENTITYMGMT-02 seed)
--   e1000001-0000-4000-8000-000000000001 = Alice (eu-west-1, active)
--   e1000001-0000-4000-8000-000000000002 = Bob   (us-east-1, active)
--   e1000001-0000-4000-8000-000000000003 = Charlie (eu-west-1, inactive)
-- ============================================================================
\set ENTITY_ALICE_ID   'e1000001-0000-4000-8000-000000000001'
\set ENTITY_BOB_ID     'e1000001-0000-4000-8000-000000000002'
\set ENTITY_CHARLIE_ID 'e1000001-0000-4000-8000-000000000003'

-- ============================================================================
-- Seed 1: entity_read_audit_log (historical read events)
--
-- Gherkin SCENARIO 1 (retrieved): Alice read 3 times, Bob read 2 times
-- Gherkin SCENARIO 2 (not_found): 2 attempts to read non-existent entities
--
-- These seed entries demonstrate the audit trail for observability.
-- Real entries are created by get_entity_by_id_with_audit() at runtime.
-- ============================================================================
WITH inserted_audits AS (
    INSERT INTO entity_read_audit_log (
        id, entity_id, request_id, outcome, is_deleted,
        read_by, request_origin, entity_status, schema_id, region,
        read_at, duration_ms
    ) VALUES
        -- Gherkin SCENARIO 1: Successful reads of Alice (eu-west-1, active)
        (
            gen_random_uuid(),
            :ENTITY_ALICE_ID,
            'req-alice-001',
            'retrieved',
            FALSE,
            'user-admin-001',
            'api-gateway',
            'active',
            'c0000001-0000-4000-8000-000000000001',
            'eu-west-1',
            NOW() - INTERVAL '10 minutes',
            12
        ),
        (
            gen_random_uuid(),
            :ENTITY_ALICE_ID,
            'req-alice-002',
            'retrieved',
            FALSE,
            'user-viewer-002',
            'dashboard-ui',
            'active',
            'c0000001-0000-4000-8000-000000000001',
            'eu-west-1',
            NOW() - INTERVAL '5 minutes',
            8
        ),
        (
            gen_random_uuid(),
            :ENTITY_ALICE_ID,
            'req-alice-003',
            'retrieved',
            FALSE,
            'internal-sync-svc',
            'internal-sync',
            'active',
            'c0000001-0000-4000-8000-000000000001',
            'eu-west-1',
            NOW() - INTERVAL '1 minute',
            15
        ),
        -- Gherkin SCENARIO 1: Successful reads of Bob (us-east-1, active)
        (
            gen_random_uuid(),
            :ENTITY_BOB_ID,
            'req-bob-001',
            'retrieved',
            FALSE,
            'user-admin-001',
            'api-gateway',
            'active',
            'c0000001-0000-4000-8000-000000000001',
            'us-east-1',
            NOW() - INTERVAL '8 minutes',
            22
        ),
        (
            gen_random_uuid(),
            :ENTITY_BOB_ID,
            'req-bob-002',
            'retrieved',
            FALSE,
            'cross-region-sync',
            'replication-worker',
            'active',
            'c0000001-0000-4000-8000-000000000001',
            'us-east-1',
            NOW() - INTERVAL '3 minutes',
            45
        ),
        -- Gherkin SCENARIO 1: Read of Charlie (eu-west-1, inactive)
        (
            gen_random_uuid(),
            :ENTITY_CHARLIE_ID,
            'req-charlie-001',
            'retrieved',
            FALSE,
            'user-auditor-003',
            'api-gateway',
            'inactive',
            'c0000001-0000-4000-8000-000000000001',
            'eu-west-1',
            NOW() - INTERVAL '7 minutes',
            18
        ),
        -- Gherkin SCENARIO 2: Non-existent entity reads (404s)
        (
            gen_random_uuid(),
            'ent-nonexistent-001',
            'req-404-001',
            'not_found',
            FALSE,
            'user-viewer-002',
            'api-gateway',
            NULL,
            NULL,
            NULL,
            NOW() - INTERVAL '2 minutes',
            5
        ),
        (
            gen_random_uuid(),
            'ent-nonexistent-002',
            'req-404-002',
            'not_found',
            FALSE,
            'unknown-user',
            'api-gateway',
            NULL,
            NULL,
            NULL,
            NOW() - INTERVAL '30 seconds',
            3
        )
    RETURNING id, entity_id, request_id, outcome, is_deleted, read_by,
              request_origin, entity_status, schema_id, region, read_at, duration_ms
)
-- ============================================================================
-- Seed 2: Outbox events — entitymanagement.entity.read
-- These represent the events that would have been enqueued when the
-- entities above were read.
--
-- Event type: 'entitymanagement.entity.read' (per Gherkin SCENARIO 1)
-- Payload matches Gherkin spec: { event_id, entity_id, entity_name, region,
--                                  read_at, request_origin }
--
-- SCENARIO 2 (not_found) entries do NOT have corresponding outbox events.
-- ============================================================================
INSERT INTO outbox_events (
    id, event_id, aggregate_id, aggregate_type,
    event_type, source, subject, payload, status, created_at
)
SELECT
    gen_random_uuid()::TEXT,
    gen_random_uuid()::TEXT,
    ia.entity_id,
    'entity',
    'entitymanagement.entity.read',
    '/api/v1/entities',
    'entity/' || ia.entity_id,
    jsonb_build_object(
        'event_id',       gen_random_uuid()::TEXT,
        'entity_id',      ia.entity_id,
        'entity_name',    CASE
                            WHEN ia.entity_id = :ENTITY_ALICE_ID THEN 'Alice'
                            WHEN ia.entity_id = :ENTITY_BOB_ID THEN 'Bob'
                            WHEN ia.entity_id = :ENTITY_CHARLIE_ID THEN 'Charlie'
                            ELSE 'unknown'
                          END,
        'region',         ia.region,
        'read_at',        ia.read_at,
        'request_origin', ia.request_origin
    ),
    'published',   -- Already published (seed data for test environments)
    ia.read_at
FROM inserted_audits ia
WHERE ia.outcome = 'retrieved';  -- SCENARIO 2: No events for not_found

-- ============================================================================
-- Seed 3: Verify the seed data (commented — uncomment for debugging)
-- ============================================================================
-- -- Verify read audit log
-- SELECT outcome, entity_id, request_origin, region, duration_ms
-- FROM entity_read_audit_log
-- ORDER BY read_at DESC;
--
-- -- Verify SCENARIO 1: entitymanagement.entity.read events exist for successful reads
-- SELECT event_type, subject, payload->>'entity_name' AS entity_name,
--        payload->>'region' AS region, payload->>'request_origin' AS origin
-- FROM outbox_events
-- WHERE event_type = 'entitymanagement.entity.read'
-- ORDER BY created_at DESC;
--
-- -- Verify SCENARIO 2: No entity.read event for 404 reads
-- SELECT COUNT(*) AS not_found_with_events
-- FROM outbox_events o
-- WHERE o.event_type = 'entitymanagement.entity.read'
--   AND o.aggregate_id IN ('ent-nonexistent-001', 'ent-nonexistent-002');
-- -- Should return 0
--
-- -- Verify aggregate read stats by origin (for ResidencyContext)
-- SELECT request_origin, region, COUNT(*) as reads,
--        AVG(duration_ms)::INTEGER AS avg_ms
-- FROM entity_read_audit_log
-- GROUP BY request_origin, region
-- ORDER BY reads DESC;
--
-- -- Verify latency percentiles (for ObservabilityContext)
-- SELECT * FROM get_read_latency_percentiles('1 hour');
-- SELECT * FROM get_read_latency_percentiles('1 hour', NULL, 'eu-west-1', NULL);
--
-- -- Verify cross-region read summary (for ResidencyContext)
-- SELECT * FROM get_cross_region_read_summary('1 day');
