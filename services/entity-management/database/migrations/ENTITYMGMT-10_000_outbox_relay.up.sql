-- Migration: ENTITYMGMT-10_000_outbox_relay.up.sql
-- Story: ENTITYMGMT-10 — Domain events are reliably published via transactional outbox pattern over NATS
-- Bounded Context: Entity Management
--
-- Prerequisites: ENTITYMGMT-01_000_schema_definition.up.sql
--   - outbox_events table (transactional outbox for CloudEvents)
--   - update_modified_column() trigger function
--
-- Extension: ENTITYMGMT-02_000_create_entities.up.sql
--   - entities table, create_entity_with_idempotency() function
--
-- ============================================================================
-- Gherkin Scenarios
-- ============================================================================
--
-- SCENARIO 1: Successful entity creation within UnitOfWork
--   Given a create entity transaction begins
--   When the entity is saved to the entities table
--     AND the EntityCreated outbox event is saved to the outbox_messages table
--   Then both operations occur within the same UnitOfWork database transaction
--     And the outbox event has status="pending"
--
-- SCENARIO 2: Outbox relay publishes pending events to NATS
--   Given an outbox event with status="pending"
--   When the outbox relay goroutine processes it
--   Then the event is published to NATS on subject "entitymanagement.entity.created"
--     And the outbox event status is updated to "published"
--     And the relay processes events in FIFO order
--
-- SCENARIO 3: Retry with exponential backoff on failure
--   Given an outbox event fails to publish to NATS (network error, NATS unavailable)
--   When the relay retries
--   Then it retries with exponential backoff (1s, 2s, 4s) up to max_retries (default 3)
--     If max retries exhausted, event status is set to "failed"
--     And a critical alert metric is incremented
--
-- SCENARIO 4: NoopEventBus fallback when NATS unavailable at startup
--   Given the NATS connection was unavailable at startup
--   When a noopEventBus fallback is used
--   Then events are logged at DEBUG level instead of published
--     And the service continues to operate in degraded mode
--
-- ============================================================================
-- Outbox Lifecycle Events (consumed by ObservabilityContext, AlertingSystem, DeadLetterQueue)
-- ============================================================================
--
-- entitymanagement.outbox.event_published:
--   Published by the outbox relay when a pending outbox event is successfully
--   delivered to NATS. Payload: {outbox_event_id, aggregate_id, event_type,
--   nats_subject, published_at, latency_ms}. Consumers: ObservabilityContext.
--
-- entitymanagement.outbox.event_failed:
--   Published by the outbox relay when an outbox event exhausts all retries
--   and is marked as 'failed'. Payload: {outbox_event_id, aggregate_id,
--   event_type, retry_count, last_error, failed_at}. Consumers: AlertingSystem
--   (trigger ops alert), DeadLetterQueue (store for manual replay).
--
-- ============================================================================
-- Changes in this migration
-- ============================================================================
--   1. Add columns to outbox_events: published_at, nats_subject, processed_at
--   2. Add relay helper functions for FIFO fetch, mark-published, mark-failed
--   3. Add functions to emit outbox lifecycle events (event_published, event_failed)
--   4. Add enhanced indexes for relay processing
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. ENHANCE outbox_events TABLE
-- ============================================================================
-- Add columns needed by the outbox relay for tracking publish completion,
-- latency measurement, and subject routing.
--
-- Gherkin SCENARIO 2 mapping:
--   "outbox event status is updated to 'published'" → published_at IS NOT NULL
--   "published to NATS on subject" → nats_subject stores the routing key
-- ============================================================================

-- Add published_at: set when the relay successfully publishes to NATS
ALTER TABLE outbox_events
    ADD COLUMN IF NOT EXISTS published_at TIMESTAMPTZ;

-- Add nats_subject: the NATS subject used for publishing (e.g., "entitymanagement.entity.created")
ALTER TABLE outbox_events
    ADD COLUMN IF NOT EXISTS nats_subject TEXT;

-- Add processed_at: set when the relay picks up the event for processing
-- (useful for detecting stalled events and latency tracking)
ALTER TABLE outbox_events
    ADD COLUMN IF NOT EXISTS processed_at TIMESTAMPTZ;

-- Add max_retries: per-event override for max retry attempts
-- NULL means use the relay's default (3)
ALTER TABLE outbox_events
    ADD COLUMN IF NOT EXISTS max_retries SMALLINT;

-- Add a comment documenting the enhanced table
COMMENT ON COLUMN outbox_events.published_at IS 'Timestamp when the outbox relay successfully published this event to NATS';
COMMENT ON COLUMN outbox_events.nats_subject IS 'NATS subject this event was published to (e.g., entitymanagement.entity.created)';
COMMENT ON COLUMN outbox_events.processed_at IS 'Timestamp when the outbox relay picked up this event for processing';
COMMENT ON COLUMN outbox_events.max_retries IS 'Per-event max retry override (NULL = use relay default of 3)';

-- ============================================================================
-- 2. INDEXES for outbox relay processing
-- ============================================================================

-- Primary relay query: FIFO fetch of pending events
-- Uses (status, created_at) for the WHERE clause and ORDER BY
-- Already created in ENTITYMGMT-01 as idx_outbox_pending_events,
-- but we recreate it with enhanced columns for clarity
DROP INDEX IF EXISTS idx_outbox_pending_events;
CREATE INDEX IF NOT EXISTS idx_outbox_pending_events
    ON outbox_events(created_at ASC, retry_count ASC)
    WHERE status = 'pending';

-- Index for relay to find stalled events (processed_at is set but published_at is NULL)
CREATE INDEX IF NOT EXISTS idx_outbox_stalled_events
    ON outbox_events(processed_at ASC, created_at ASC)
    WHERE status = 'pending' AND processed_at IS NOT NULL;

-- Index for latency queries: published events by publication time
CREATE INDEX IF NOT EXISTS idx_outbox_published_at
    ON outbox_events(published_at DESC)
    WHERE status = 'published';

-- Composite index for lifecycle event queries (published events per subject)
CREATE INDEX IF NOT EXISTS idx_outbox_published_subject
    ON outbox_events(nats_subject, published_at DESC)
    WHERE status = 'published';

-- Enhanced failed events index (already exists as idx_outbox_failed from ENTITYMGMT-01)
DROP INDEX IF EXISTS idx_outbox_failed;
CREATE INDEX IF NOT EXISTS idx_outbox_failed
    ON outbox_events(retry_count DESC, created_at ASC)
    WHERE status = 'failed';

-- Add index for aggregate+type queries used by lifecycle events
CREATE INDEX IF NOT EXISTS idx_outbox_aggregate_type
    ON outbox_events(aggregate_type, aggregate_id, event_type);

-- ============================================================================
-- 3. RELAY HELPER FUNCTIONS
-- ============================================================================

-- ---------------------------------------------------------------------------
-- FUNCTION: fetch_pending_outbox_events(batch_size)
--
-- Fetches the oldest pending outbox events in FIFO order using FOR UPDATE
-- SKIP LOCKED to prevent concurrent relay instances from processing the same
-- events. This ensures at-least-once delivery semantics.
--
-- Gherkin SCENARIO 2: "relay processes events in FIFO order"
--   → ORDER BY created_at ASC, id ASC
--
-- Gherkin SCENARIO 3: "retries with exponential backoff"
--   → Events with retry_count > 0 are also fetched (pending = pending)
--
-- Usage (from Go outbox_relay.go):
--   SELECT * FROM fetch_pending_outbox_events(50);
-- ============================================================================
CREATE OR REPLACE FUNCTION fetch_pending_outbox_events(
    p_batch_size INTEGER DEFAULT 50
)
RETURNS TABLE(
    out_id              TEXT,
    out_event_id        TEXT,
    out_aggregate_id    TEXT,
    out_aggregate_type  TEXT,
    out_event_type      TEXT,
    out_source          TEXT,
    out_subject         TEXT,
    out_payload         JSONB,
    out_status          TEXT,
    out_retry_count     INTEGER,
    out_last_error      TEXT,
    out_created_at      TIMESTAMPTZ,
    out_max_retries     SMALLINT
) AS $$
BEGIN
    RETURN QUERY
    UPDATE outbox_events
    SET
        processed_at = NOW()
    WHERE id IN (
        SELECT oe.id
        FROM outbox_events oe
        WHERE oe.status = 'pending'
        ORDER BY oe.created_at ASC, oe.id ASC
        LIMIT p_batch_size
        FOR UPDATE SKIP LOCKED
    )
    RETURNING
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
        created_at,
        max_retries;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION fetch_pending_outbox_events(INTEGER) IS
'Fetches the oldest pending outbox events in FIFO order using FOR UPDATE SKIP LOCKED for concurrent safety. Sets processed_at on fetched events.';

-- ---------------------------------------------------------------------------
-- FUNCTION: mark_outbox_published(event_id, nats_subject)
--
-- Marks a pending outbox event as successfully published to NATS.
-- Sets status='published', published_at=NOW(), and records the NATS subject.
--
-- Gherkin SCENARIO 2: "outbox event status is updated to 'published'"
--   → status = 'published', published_at = NOW()
--
-- Returns the number of rows updated (should be 1).
--
-- Usage:
--   SELECT mark_outbox_published(
--     'abc-123-def',
--     'entitymanagement.entity.created'
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION mark_outbox_published(
    p_event_id      TEXT,
    p_nats_subject  TEXT
)
RETURNS INTEGER AS $$
DECLARE
    v_updated INTEGER;
BEGIN
    UPDATE outbox_events
    SET
        status        = 'published',
        published_at  = NOW(),
        nats_subject  = p_nats_subject,
        last_error    = NULL
    WHERE id = p_event_id
      AND status = 'pending';

    GET DIAGNOSTICS v_updated = ROW_COUNT;
    RETURN v_updated;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION mark_outbox_published(TEXT, TEXT) IS
'Marks an outbox event as published. Sets status="published", records NATS subject and timestamp. Returns number of rows updated.';

-- ---------------------------------------------------------------------------
-- FUNCTION: mark_outbox_failed(event_id, error_message)
--
-- Marks a pending outbox event as failed after exhausting retries.
-- Increments retry_count and records the error message.
--
-- Gherkin SCENARIO 3: "If max retries exhausted, event status is set to 'failed'"
--   → status = 'failed', retry_count incremented, last_error set
--
-- Returns the updated retry_count.
--
-- Usage:
--   SELECT mark_outbox_failed(
--     'abc-123-def',
--     'NATS connection refused: connection refused'
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION mark_outbox_failed(
    p_event_id      TEXT,
    p_error_message TEXT
)
RETURNS INTEGER AS $$
DECLARE
    v_retry_count INTEGER;
BEGIN
    UPDATE outbox_events
    SET
        status      = 'failed',
        retry_count = retry_count + 1,
        last_error  = p_error_message
    WHERE id = p_event_id
      AND status = 'pending'
    RETURNING retry_count INTO v_retry_count;

    RETURN v_retry_count;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION mark_outbox_failed(TEXT, TEXT) IS
'Marks an outbox event as failed. Sets status="failed", increments retry_count, records error. Returns updated retry_count.';

-- ---------------------------------------------------------------------------
-- FUNCTION: mark_outbox_retry(event_id, error_message)
--
-- Records a retry attempt on a pending outbox event (without marking it
-- as permanently failed). Increments retry_count, records the error,
-- and keeps status='pending' so the relay will retry.
--
-- Gherkin SCENARIO 3: "retries with exponential backoff"
--   → retry_count is incremented, status remains 'pending' for retry
--
-- Returns the current retry_count after increment.
--
-- Usage:
--   SELECT mark_outbox_retry(
--     'abc-123-def',
--     'NATS publish timeout (attempt 1/3)'
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION mark_outbox_retry(
    p_event_id      TEXT,
    p_error_message TEXT
)
RETURNS INTEGER AS $$
DECLARE
    v_retry_count INTEGER;
BEGIN
    UPDATE outbox_events
    SET
        retry_count = retry_count + 1,
        last_error  = p_error_message
    WHERE id = p_event_id
      AND status = 'pending'
    RETURNING retry_count INTO v_retry_count;

    RETURN v_retry_count;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION mark_outbox_retry(TEXT, TEXT) IS
'Increments retry_count and records error for a pending event. Status remains "pending" so the relay will retry. Returns updated retry_count.';

-- ---------------------------------------------------------------------------
-- FUNCTION: get_outbox_latency_ms(event_id)
--
-- Computes the end-to-end latency of an outbox event from creation to
-- successful publication. Returns NULL if the event hasn't been published.
--
-- Used by the event_published lifecycle event and monitoring dashboards.
--
-- Gherkin SCENARIO 2: latency tracking for ObservabilityContext
--
-- Usage:
--   SELECT get_outbox_latency_ms('abc-123-def');
-- ============================================================================
CREATE OR REPLACE FUNCTION get_outbox_latency_ms(
    p_event_id TEXT
)
RETURNS BIGINT AS $$
DECLARE
    v_latency_ms BIGINT;
BEGIN
    SELECT
        EXTRACT(EPOCH FROM (published_at - created_at))::BIGINT * 1000
        + EXTRACT(MILLISECOND FROM (published_at - created_at))::BIGINT
        AS latency_ms
    INTO v_latency_ms
    FROM outbox_events
    WHERE id = p_event_id
      AND published_at IS NOT NULL;

    RETURN v_latency_ms;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION get_outbox_latency_ms(TEXT) IS
'Returns the end-to-end latency in milliseconds from event creation to NATS publication.';

-- ============================================================================
-- 4. OUTBOX LIFECYCLE EVENT FUNCTIONS
-- ============================================================================
-- These functions enqueue lifecycle events (event_published, event_failed)
-- into the outbox_events table. These events are consumed by:
--   - ObservabilityContext: delivery latency metrics, throughput monitoring
--   - AlertingSystem: trigger ops alert on permanent failures
--   - DeadLetterQueue: store failed events for manual replay
--
-- The relay processes these lifecycle events the same way as domain events,
-- publishing them to NATS subjects:
--   entitymanagement.outbox.event_published
--   entitymanagement.outbox.event_failed
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- FUNCTION: enqueue_outbox_event_published(outbox_event_id, aggregate_id,
--                                           event_type, nats_subject,
--                                           published_at, latency_ms)
--
-- Enqueues an entitymanagement.outbox.event_published lifecycle event into
-- the outbox_events table. Called by the outbox relay AFTER successfully
-- publishing a domain event to NATS.
--
-- Gherkin SCENARIO 2 extension:
--   "entitymanagement.outbox.event_published — Published by the outbox relay
--    when a pending outbox event is successfully delivered to NATS."
--
-- Returns the outbox event ID of the lifecycle event.
--
-- Usage:
--   PERFORM enqueue_outbox_event_published(
--     'outbox-abc', 'entity-123', 'entity.created',
--     'entitymanagement.entity.created', NOW(), 42
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION enqueue_outbox_event_published(
    p_outbox_event_id   TEXT,
    p_aggregate_id      TEXT,
    p_event_type        TEXT,
    p_nats_subject      TEXT,
    p_published_at      TIMESTAMPTZ,
    p_latency_ms        BIGINT
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
        p_outbox_event_id,
        'outbox_event',
        'entitymanagement.outbox.event_published',
        '/entity-manager',
        'outbox/published/' || p_outbox_event_id,
        jsonb_build_object(
            'outbox_event_id', p_outbox_event_id,
            'aggregate_id',    p_aggregate_id,
            'event_type',      p_event_type,
            'nats_subject',    p_nats_subject,
            'published_at',    p_published_at,
            'latency_ms',      p_latency_ms
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

COMMENT ON FUNCTION enqueue_outbox_event_published(TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ, BIGINT) IS
'Enqueues an entitymanagement.outbox.event_published lifecycle event tracking successful NATS delivery with latency metrics.';

-- ---------------------------------------------------------------------------
-- FUNCTION: enqueue_outbox_event_failed(outbox_event_id, aggregate_id,
--                                        event_type, retry_count,
--                                        last_error, failed_at)
--
-- Enqueues an entitymanagement.outbox.event_failed lifecycle event into
-- the outbox_events table. Called by the outbox relay AFTER an event has
-- exhausted all retry attempts.
--
-- Gherkin SCENARIO 3 extension:
--   "entitymanagement.outbox.event_failed — Published when an outbox event
--    exhausts all retries and is marked as 'failed'."
--
-- Returns the outbox event ID of the lifecycle event.
--
-- Usage:
--   PERFORM enqueue_outbox_event_failed(
--     'outbox-abc', 'entity-123', 'entity.created',
--     3, 'NATS connection refused', NOW()
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION enqueue_outbox_event_failed(
    p_outbox_event_id   TEXT,
    p_aggregate_id      TEXT,
    p_event_type        TEXT,
    p_retry_count       INTEGER,
    p_last_error        TEXT,
    p_failed_at         TIMESTAMPTZ
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
        p_outbox_event_id,
        'outbox_event',
        'entitymanagement.outbox.event_failed',
        '/entity-manager',
        'outbox/failed/' || p_outbox_event_id,
        jsonb_build_object(
            'outbox_event_id', p_outbox_event_id,
            'aggregate_id',    p_aggregate_id,
            'event_type',      p_event_type,
            'retry_count',     p_retry_count,
            'last_error',      p_last_error,
            'failed_at',       p_failed_at
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

COMMENT ON FUNCTION enqueue_outbox_event_failed(TEXT, TEXT, TEXT, INTEGER, TEXT, TIMESTAMPTZ) IS
'Enqueues an entitymanagement.outbox.event_failed lifecycle event for alerting and dead-letter queue processing.';

-- ============================================================================
-- 5. RELAY MANAGEMENT FUNCTIONS
-- ============================================================================

-- ---------------------------------------------------------------------------
-- FUNCTION: count_pending_outbox_events()
--
-- Returns the total number of pending outbox events awaiting processing.
-- Useful for monitoring relay backlog.
--
-- Gherkin: monitoring the relay's backlog depth.
--
-- Usage:
--   SELECT count_pending_outbox_events();
-- ============================================================================
CREATE OR REPLACE FUNCTION count_pending_outbox_events()
RETURNS BIGINT AS $$
DECLARE
    v_count BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM outbox_events
    WHERE status = 'pending';
    RETURN v_count;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION count_pending_outbox_events() IS
'Returns the total number of pending outbox events awaiting relay processing.';

-- ---------------------------------------------------------------------------
-- FUNCTION: count_stalled_outbox_events(stall_threshold_seconds)
--
-- Returns the number of events that have been picked up by the relay
-- (processed_at is set) but not yet published (published_at is NULL),
-- indicating a potential relay stall or crash.
--
-- Gherkin: detecting relay failures for alerting.
--
-- Usage:
--   SELECT count_stalled_outbox_events(60);  -- stalled for > 60 seconds
-- ============================================================================
CREATE OR REPLACE FUNCTION count_stalled_outbox_events(
    p_stall_threshold_seconds INTEGER DEFAULT 60
)
RETURNS BIGINT AS $$
DECLARE
    v_count BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM outbox_events
    WHERE status = 'pending'
      AND processed_at IS NOT NULL
      AND processed_at < NOW() - (p_stall_threshold_seconds || ' seconds')::INTERVAL;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION count_stalled_outbox_events(INTEGER) IS
'Returns the count of events picked up by the relay but not published within the threshold, indicating a potential relay stall.';

-- ---------------------------------------------------------------------------
-- FUNCTION: reset_stalled_outbox_events(stall_threshold_seconds)
--
-- Resets stalled events by clearing processed_at so the relay picks them up
-- again. Use this as a recovery mechanism if the relay crashes mid-processing.
--
-- Returns the number of events reset.
--
-- Usage:
--   SELECT reset_stalled_outbox_events(120);  -- reset events stalled > 2 min
-- ============================================================================
CREATE OR REPLACE FUNCTION reset_stalled_outbox_events(
    p_stall_threshold_seconds INTEGER DEFAULT 120
)
RETURNS INTEGER AS $$
DECLARE
    v_reset INTEGER;
BEGIN
    UPDATE outbox_events
    SET
        processed_at = NULL
    WHERE status = 'pending'
      AND processed_at IS NOT NULL
      AND processed_at < NOW() - (p_stall_threshold_seconds || ' seconds')::INTERVAL;

    GET DIAGNOSTICS v_reset = ROW_COUNT;
    RETURN v_reset;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION reset_stalled_outbox_events(INTEGER) IS
'Clears processed_at on stalled events so the relay picks them up again. Returns count of reset events.';

-- ============================================================================
-- 6. OUTBOX EVENT QUERY FUNCTIONS
-- ============================================================================

-- ---------------------------------------------------------------------------
-- FUNCTION: get_outbox_event_by_id(event_id)
--
-- Retrieves a single outbox event by its primary key (id).
-- Returns NULL if not found.
--
-- Usage:
--   SELECT * FROM get_outbox_event_by_id('abc-123-def');
-- ============================================================================
CREATE OR REPLACE FUNCTION get_outbox_event_by_id(
    p_event_id TEXT
)
RETURNS TABLE(
    out_id              TEXT,
    out_event_id        TEXT,
    out_aggregate_id    TEXT,
    out_aggregate_type  TEXT,
    out_event_type      TEXT,
    out_source          TEXT,
    out_subject         TEXT,
    out_payload         JSONB,
    out_status          TEXT,
    out_retry_count     INTEGER,
    out_last_error      TEXT,
    out_created_at      TIMESTAMPTZ,
    out_published_at    TIMESTAMPTZ,
    out_nats_subject    TEXT,
    out_processed_at    TIMESTAMPTZ,
    out_max_retries     SMALLINT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        id, event_id, aggregate_id, aggregate_type,
        event_type, source, subject, payload,
        status, retry_count, last_error, created_at,
        published_at, nats_subject, processed_at, max_retries
    FROM outbox_events
    WHERE id = p_event_id;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION get_outbox_event_by_id(TEXT) IS
'Retrieves a single outbox event by its primary key ID.';

-- ---------------------------------------------------------------------------
-- FUNCTION: list_failed_outbox_events(limit, offset)
--
-- Lists permanently failed outbox events for dead-letter queue review.
-- Ordered by most recently failed first.
--
-- Gherkin SCENARIO 3: DeadLetterQueue consumes event_failed for manual replay
--
-- Usage:
--   SELECT * FROM list_failed_outbox_events(20, 0);
-- ============================================================================
CREATE OR REPLACE FUNCTION list_failed_outbox_events(
    p_limit  INTEGER DEFAULT 20,
    p_offset INTEGER DEFAULT 0
)
RETURNS TABLE(
    out_id              TEXT,
    out_event_id        TEXT,
    out_aggregate_id    TEXT,
    out_aggregate_type  TEXT,
    out_event_type      TEXT,
    out_source          TEXT,
    out_subject         TEXT,
    out_payload         JSONB,
    out_retry_count     INTEGER,
    out_last_error      TEXT,
    out_created_at      TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        id, event_id, aggregate_id, aggregate_type,
        event_type, source, subject, payload,
        retry_count, last_error, created_at
    FROM outbox_events
    WHERE status = 'failed'
    ORDER BY created_at DESC
    LIMIT p_limit
    OFFSET p_offset;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION list_failed_outbox_events(INTEGER, INTEGER) IS
'Lists permanently failed outbox events for dead-letter queue review, ordered by most recent first.';

-- ---------------------------------------------------------------------------
-- FUNCTION: replay_failed_outbox_event(event_id)
--
-- Resets a failed outbox event back to 'pending' with retry_count=0,
-- allowing the relay to retry it. For manual replay via DeadLetterQueue.
--
-- Gherkin SCENARIO 3: DeadLetterQueue stores failed events for manual replay
--
-- Returns the event ID if reset, NULL if not found or not in 'failed' status.
--
-- Usage:
--   SELECT replay_failed_outbox_event('abc-123-def');
-- ============================================================================
CREATE OR REPLACE FUNCTION replay_failed_outbox_event(
    p_event_id TEXT
)
RETURNS TEXT AS $$
DECLARE
    v_id TEXT;
BEGIN
    UPDATE outbox_events
    SET
        status        = 'pending',
        retry_count   = 0,
        last_error    = NULL,
        processed_at  = NULL
    WHERE id = p_event_id
      AND status = 'failed'
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION replay_failed_outbox_event(TEXT) IS
'Resets a failed outbox event back to pending for retry. Returns the event ID or NULL.';

-- ============================================================================
-- 7. REDIS CACHE CONFIGURATION (embedded documentation)
-- ============================================================================
-- The following Redis key patterns are used by the outbox relay for
-- performance optimization and rate limiting:
--
-- Cache Key Pattern                         | TTL   | Purpose
-- ------------------------------------------|-------|---------------------------------------
-- outbox:relay:last_poll                    | 10s   | Prevent duplicate relay cycles
-- outbox:relay:stall_count                  | 60s   | Running count of stalled events
-- outbox:relay:consecutive_failures         | 300s  | Circuit breaker for relay
-- outbox:relay:last_published:{event_type}  | 3600s | Last published timestamp per type
-- outbox:relay:rate_limit:{event_type}      | 1s    | Rate limiter for lifecycle events
--
-- ============================================================================

COMMIT;
