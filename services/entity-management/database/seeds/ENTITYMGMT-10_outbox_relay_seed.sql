-- Seed script: ENTITYMGMT-10 outbox relay test data
-- Bounded Context: Entity Management
-- Story: ENTITYMGMT-10 — Domain events are reliably published via transactional outbox pattern over NATS
--
-- This seed creates realistic test scenarios for the outbox relay:
--   1. A pending entity.created event (normal case)
--   2. A pending entity.updated event (queued for relay)
--   3. A pending entity.deleted event (with one prior retry)
--   4. A successfully published event (for history/audit)
--   5. A permanently failed event (for DLQ testing)
--   6. A stalled event (processed_at set but not published)
--   7. An outbox lifecycle event_published event
--   8. An outbox lifecycle event_failed event
--
-- Gherkin coverage:
--   SCENARIO 1: seed rows 1-3 (pending events within UnitOfWork)
--   SCENARIO 2: seed row 4 (published event, FIFO order)
--   SCENARIO 3: seed rows 5, 6 (failed event, retry scenario, stalled event)
--   SCENARIO 4: noop fallback (tested in-memory, no seed needed)
-- ============================================================================

BEGIN;

-- ============================================================================
-- Helper function to generate UUID-based event IDs for readability
-- ============================================================================
DO $$
DECLARE
    v_entity_id_1      TEXT := 'e0000001-0000-4000-8000-000000000001';
    v_entity_id_2      TEXT := 'e0000002-0000-4000-8000-000000000002';
    v_entity_id_3      TEXT := 'e0000003-0000-4000-8000-000000000003';
    v_schema_id        TEXT := 'c0000001-0000-4000-8000-000000000001';
    v_now              TIMESTAMPTZ := NOW();
    v_five_min_ago     TIMESTAMPTZ := NOW() - INTERVAL '5 minutes';
    v_ten_min_ago      TIMESTAMPTZ := NOW() - INTERVAL '10 minutes';
    v_one_hour_ago     TIMESTAMPTZ := NOW() - INTERVAL '1 hour';
    v_two_hours_ago    TIMESTAMPTZ := NOW() - INTERVAL '2 hours';
    v_yesterday        TIMESTAMPTZ := NOW() - INTERVAL '1 day';
BEGIN

    -- ========================================================================
    -- SCENARIO 1 & 2: Pending events awaiting relay processing
    -- ========================================================================

    -- Row 1: entity.created event for "Customer-001" (normal FIFO case)
    INSERT INTO outbox_events (
        id, event_id, aggregate_id, aggregate_type,
        event_type, source, subject, payload,
        status, retry_count, last_error, created_at,
        published_at, nats_subject, processed_at, max_retries
    ) VALUES (
        'outbox-0001-0000-4000-8000-000000000001',
        'evt-0001-0000-4000-8000-000000000001',
        v_entity_id_1,
        'entity',
        'entity.created',
        '/entity-manager',
        'entity/' || v_entity_id_1,
        jsonb_build_object(
            'event_id',       'evt-0001-0000-4000-8000-000000000001',
            'entity_id',      v_entity_id_1,
            'entity_name',    'Customer-001',
            'entity_type',    'customer',
            'region',         'eu-west-1',
            'data_residency_zone', 'eu',
            'schema_id',      v_schema_id,
            'version',        1,
            'status',         'active',
            'attributes',     jsonb_build_object('email', 'customer001@example.com', 'name', 'Customer 001'),
            'metadata',       '{}'::jsonb,
            'occurred_at',    v_ten_min_ago
        ),
        'pending',  -- Gherkin SCENARIO 1: status = "pending"
        0,
        NULL,
        v_ten_min_ago,
        NULL,  -- Not yet published
        NULL,  -- No NATS subject yet
        NULL,  -- Not yet processed
        NULL   -- Use relay default (3)
    )
    ON CONFLICT (id) DO NOTHING;

    -- Row 2: entity.updated event for same entity (queued after create)
    INSERT INTO outbox_events (
        id, event_id, aggregate_id, aggregate_type,
        event_type, source, subject, payload,
        status, retry_count, last_error, created_at,
        published_at, nats_subject, processed_at, max_retries
    ) VALUES (
        'outbox-0002-0000-4000-8000-000000000002',
        'evt-0002-0000-4000-8000-000000000002',
        v_entity_id_1,
        'entity',
        'entity.updated',
        '/entity-manager',
        'entity/' || v_entity_id_1,
        jsonb_build_object(
            'event_id',         'evt-0002-0000-4000-8000-000000000002',
            'entity_id',        v_entity_id_1,
            'entity_name',      'Customer-001',
            'status',           'active',
            'region',           'eu-west-1',
            'previous_version', 1,
            'new_version',      2,
            'changed_fields',   '["name"]',
            'occurred_at',      v_five_min_ago
        ),
        'pending',
        0,
        NULL,
        v_five_min_ago,
        NULL,
        NULL,
        NULL,
        NULL
    )
    ON CONFLICT (id) DO NOTHING;

    -- Row 3: entity.deleted event (queued after update)
    INSERT INTO outbox_events (
        id, event_id, aggregate_id, aggregate_type,
        event_type, source, subject, payload,
        status, retry_count, last_error, created_at,
        published_at, nats_subject, processed_at, max_retries
    ) VALUES (
        'outbox-0003-0000-4000-8000-000000000003',
        'evt-0003-0000-4000-8000-000000000003',
        v_entity_id_2,
        'entity',
        'entity.deleted',
        '/entity-manager',
        'entity/' || v_entity_id_2,
        jsonb_build_object(
            'event_id',       'evt-0003-0000-4000-8000-000000000003',
            'entity_id',      v_entity_id_2,
            'entity_name',    'Customer-002',
            'region',         'us-east-1',
            'deleted_at',     v_five_min_ago,
            'occurred_at',    v_five_min_ago
        ),
        'pending',
        0,
        NULL,
        v_five_min_ago,
        NULL,
        NULL,
        NULL,
        NULL
    )
    ON CONFLICT (id) DO NOTHING;

    -- Row 4: entity.created with 1 prior retry (SCENARIO 3: retry scenario)
    INSERT INTO outbox_events (
        id, event_id, aggregate_id, aggregate_type,
        event_type, source, subject, payload,
        status, retry_count, last_error, created_at,
        published_at, nats_subject, processed_at, max_retries
    ) VALUES (
        'outbox-0004-0000-4000-8000-000000000004',
        'evt-0004-0000-4000-8000-000000000004',
        v_entity_id_3,
        'entity',
        'entity.created',
        '/entity-manager',
        'entity/' || v_entity_id_3,
        jsonb_build_object(
            'event_id',       'evt-0004-0000-4000-8000-000000000004',
            'entity_id',      v_entity_id_3,
            'entity_name',    'Customer-003',
            'entity_type',    'customer',
            'region',         'ap-southeast-1',
            'data_residency_zone', 'ap-southeast',
            'schema_id',      v_schema_id,
            'version',        1,
            'status',         'active',
            'attributes',     jsonb_build_object('email', 'customer003@example.com', 'name', 'Customer 003'),
            'metadata',       '{}'::jsonb,
            'occurred_at',    v_one_hour_ago
        ),
        'pending',  -- Still pending after 1 retry
        1,           -- 1 prior failed attempt
        'NATS publish timeout: i/o timeout after 5s',
        v_one_hour_ago,
        NULL,
        NULL,
        v_one_hour_ago,  -- Was picked up by relay before
        5                -- Override: allow up to 5 retries
    )
    ON CONFLICT (id) DO NOTHING;

    -- ========================================================================
    -- SCENARIO 2: Successfully published event (history/audit)
    -- ========================================================================
    INSERT INTO outbox_events (
        id, event_id, aggregate_id, aggregate_type,
        event_type, source, subject, payload,
        status, retry_count, last_error, created_at,
        published_at, nats_subject, processed_at, max_retries
    ) VALUES (
        'outbox-0005-0000-4000-8000-000000000005',
        'evt-0005-0000-4000-8000-000000000005',
        'e0000004-0000-4000-8000-000000000004',
        'entity',
        'entity.created',
        '/entity-manager',
        'entity/e0000004-0000-4000-8000-000000000004',
        jsonb_build_object(
            'event_id',  'evt-0005-0000-4000-8000-000000000005',
            'entity_id', 'e0000004-0000-4000-8000-000000000004',
            'entity_name', 'Published-Entity',
            'entity_type', 'test',
            'region',      'eu-west-1',
            'occurred_at', v_yesterday
        ),
        'published',            -- Gherkin SCENARIO 2: status = "published"
        0,
        NULL,
        v_yesterday,
        v_yesterday + INTERVAL '500 milliseconds',  -- Published 500ms later
        'entitymanagement.entity.created',           -- NATS subject used
        v_yesterday + INTERVAL '500 milliseconds',
        3
    )
    ON CONFLICT (id) DO NOTHING;

    -- ========================================================================
    -- SCENARIO 3: Permanently failed event (for DLQ testing)
    -- ========================================================================
    INSERT INTO outbox_events (
        id, event_id, aggregate_id, aggregate_type,
        event_type, source, subject, payload,
        status, retry_count, last_error, created_at,
        published_at, nats_subject, processed_at, max_retries
    ) VALUES (
        'outbox-0006-0000-4000-8000-000000000006',
        'evt-0006-0000-4000-8000-000000000006',
        'e0000005-0000-4000-8000-000000000005',
        'entity',
        'entity.updated',
        '/entity-manager',
        'entity/e0000005-0000-4000-8000-000000000005',
        jsonb_build_object(
            'event_id', 'evt-0006-0000-4000-8000-000000000006',
            'entity_id', 'e0000005-0000-4000-8000-000000000005',
            'entity_name', 'Failed-Entity',
            'status', 'active',
            'region', 'eu-west-1',
            'previous_version', 1,
            'new_version', 2,
            'changed_fields', '["status"]',
            'occurred_at', v_two_hours_ago
        ),
        'failed',               -- Gherkin SCENARIO 3: status = "failed"
        3,                       -- Exhausted 3 retries
        'NATS connection refused: dial tcp 127.0.0.1:4222: connect: connection refused',
        v_two_hours_ago,
        NULL,
        NULL,
        v_two_hours_ago + INTERVAL '7 seconds',  -- Last retry attempt time
        3                         -- Default max retries
    )
    ON CONFLICT (id) DO NOTHING;

    -- ========================================================================
    -- Stalled event: processed_at set but not published (crash recovery test)
    -- ========================================================================
    INSERT INTO outbox_events (
        id, event_id, aggregate_id, aggregate_type,
        event_type, source, subject, payload,
        status, retry_count, last_error, created_at,
        published_at, nats_subject, processed_at, max_retries
    ) VALUES (
        'outbox-0007-0000-4000-8000-000000000007',
        'evt-0007-0000-4000-8000-000000000007',
        'e0000006-0000-4000-8000-000000000006',
        'entity',
        'entity.created',
        '/entity-manager',
        'entity/e0000006-0000-4000-8000-000000000006',
        jsonb_build_object(
            'event_id',  'evt-0007-0000-4000-8000-000000000007',
            'entity_id', 'e0000006-0000-4000-8000-000000000006',
            'entity_name', 'Stalled-Entity',
            'entity_type', 'test',
            'region',      'us-east-1',
            'occurred_at', v_one_hour_ago
        ),
        'pending',              -- Still pending but...
        0,
        NULL,
        v_one_hour_ago,
        NULL,                    -- Not published
        NULL,
        v_one_hour_ago + INTERVAL '2 seconds',  -- Picked up but never completed
        3
    )
    ON CONFLICT (id) DO NOTHING;

    -- ========================================================================
    -- Outbox lifecycle events (for relay self-testing)
    -- ========================================================================

    -- Lifecycle event: event_published (previously emitted by relay)
    INSERT INTO outbox_events (
        id, event_id, aggregate_id, aggregate_type,
        event_type, source, subject, payload,
        status, retry_count, last_error, created_at
    ) VALUES (
        'outbox-life-0001-0000-4000-8000-000000000001',
        'evt-life-0001-0000-4000-8000-000000000001',
        'outbox-0005-0000-4000-8000-000000000005',  -- references the published event
        'outbox_event',
        'entitymanagement.outbox.event_published',
        '/entity-manager',
        'outbox/published/outbox-0005-0000-4000-8000-000000000005',
        jsonb_build_object(
            'outbox_event_id', 'outbox-0005-0000-4000-8000-000000000005',
            'aggregate_id',    'e0000004-0000-4000-8000-000000000004',
            'event_type',      'entity.created',
            'nats_subject',    'entitymanagement.entity.created',
            'published_at',    (v_yesterday + INTERVAL '500 milliseconds'),
            'latency_ms',      500
        ),
        'published',
        0,
        NULL,
        v_yesterday + INTERVAL '500 milliseconds'
    )
    ON CONFLICT (id) DO NOTHING;

    -- Lifecycle event: event_failed (previously emitted by relay)
    INSERT INTO outbox_events (
        id, event_id, aggregate_id, aggregate_type,
        event_type, source, subject, payload,
        status, retry_count, last_error, created_at
    ) VALUES (
        'outbox-life-0002-0000-4000-8000-000000000002',
        'evt-life-0002-0000-4000-8000-000000000002',
        'outbox-0006-0000-4000-8000-000000000006',  -- references the failed event
        'outbox_event',
        'entitymanagement.outbox.event_failed',
        '/entity-manager',
        'outbox/failed/outbox-0006-0000-4000-8000-000000000006',
        jsonb_build_object(
            'outbox_event_id', 'outbox-0006-0000-4000-8000-000000000006',
            'aggregate_id',    'e0000005-0000-4000-8000-000000000005',
            'event_type',      'entity.updated',
            'retry_count',     3,
            'last_error',      'NATS connection refused: dial tcp 127.0.0.1:4222: connect: connection refused',
            'failed_at',       (v_two_hours_ago + INTERVAL '7 seconds')
        ),
        'failed',
        0,
        NULL,
        v_two_hours_ago + INTERVAL '7 seconds'
    )
    ON CONFLICT (id) DO NOTHING;

END $$;

COMMIT;
