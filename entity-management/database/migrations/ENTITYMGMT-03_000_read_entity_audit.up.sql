-- Migration: ENTITYMGMT-03_000_read_entity_audit.up.sql
-- Story: ENTITYMGMT-03 — User retrieves an entity by ID with observability event
-- Bounded Context: Entity Management
--
-- Prerequisites:
--   - ENTITYMGMT-01_000_schema_definition.up.sql
--     (entity_schemas, entity_schema_attributes, outbox_events, update_modified_column())
--   - ENTITYMGMT-02_000_create_entities.up.sql
--     (entities, request_idempotency, entity_status ENUM, get_entity_by_id(), etc.)
--
-- ============================================================================
-- Gherkin Scenarios
-- ============================================================================
--
-- SCENARIO 1: Successful entity retrieval with observability event
--   Given an entity with ID "ent-abc-123" exists
--   When a GET /api/v1/entities/ent-abc-123 request is made
--   Then the full entity payload is returned (HTTP 200)
--     Including all attributes, schema_id, region, status, version,
--       created_at, updated_at
--     And an entitymanagement.entity.read domain event is published
--       (fire-and-forget, non-blocking)
--
-- SCENARIO 2: Non-existent entity returns 404 without event
--   Given an entity with ID "ent-nonexistent" does not exist
--   When a GET /api/v1/entities/ent-nonexistent request is made
--   Then HTTP 404 is returned with ErrorResponse
--       {code: "NOT_FOUND", message: "entity not found"}
--     And no entity.read event is published
--
-- ============================================================================
-- Domain Events
-- ============================================================================
--
-- entitymanagement.entity.read — Published fire-and-forget when an entity
--   is successfully retrieved by ID. NOT published on 404 responses.
--   Owned by EntityManagement context.
--
--   Payload (per Gherkin spec):
--     { event_id, entity_id, entity_name, region, read_at, request_origin }
--
--   Consumers:
--     ObservabilityContext  (read latency metrics, access audit)
--     ResidencyContext      (cross-region read tracking)
--
-- ============================================================================
-- Tables created by this migration
-- ============================================================================
--   entity_read_audit_log  — Immutable append-only audit trail for entity
--                            reads. Used for observability, metrics, and
--                            cross-region access tracking.
--
-- Functions created:
--   log_entity_read()                        — Records a read event to the audit log
--   enqueue_entity_read_event()              — Enqueues entitymanagement.entity.read
--                                              event to the transactional outbox
--   get_entity_by_id_with_audit()            — Combined: retrieve entity + log audit
--                                              + enqueue read event (all atomic)
--   get_read_audit_trail()                   — Query read audit history for an entity
--   prune_expired_read_audit_logs()          — TTL-based cleanup (default 90-day retention)
--
-- ============================================================================

BEGIN;

-- ============================================================================
-- TABLE: entity_read_audit_log
-- Immutable append-only audit trail for all entity read operations.
-- Each row records who read which entity, when, what the outcome was, and
-- the latency of the read operation.
--
-- This table serves as the observability datasource for:
--   - Read latency metrics (p50, p95, p99 by schema, region, or consumer)
--   - Access audit logs ("who read what entity and when?")
--   - Cross-region read tracking (ResidencyContext consumer)
--   - 404 spike detection (not_found outcomes)
--
-- Gherkin mapping:
--   SCENARIO 1 (successful read) →
--     outcome = 'retrieved', entity_status = 'active'|'inactive'|'deleted'
--   SCENARIO 2 (not found) →
--     outcome = 'not_found'
--
-- This table is APPEND-ONLY: no updates, no deletes (except by TTL cleanup).
-- ============================================================================
CREATE TABLE IF NOT EXISTS entity_read_audit_log (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- The entity that was read (NULL for not_found outcomes)
    entity_id       VARCHAR(64),

    -- The request ID / trace ID for correlating reads across services
    request_id      VARCHAR(255),

    -- Outcome classification
    outcome         VARCHAR(32) NOT NULL DEFAULT 'retrieved'
                    CHECK (outcome IN ('retrieved', 'not_found')),

    -- Whether the entity was soft-deleted at the time of read
    is_deleted      BOOLEAN NOT NULL DEFAULT FALSE,

    -- Who performed the read (from auth context / JWT subject, if available)
    read_by         VARCHAR(255),

    -- The origin/source of the read request (e.g., 'api-gateway', 'internal-sync')
    -- This maps to the 'request_origin' field in the domain event payload
    request_origin  VARCHAR(128),

    -- Response metadata for observability aggregation
    entity_status   entity_status,  -- Snapshot of entity status at read time
    schema_id       UUID,           -- Schema reference for aggregation queries
    region          VARCHAR(64),    -- Entity region for geographic observability

    -- Timing
    read_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    duration_ms     INTEGER,        -- Read latency in milliseconds (for p50/p95/p99 metrics)

    -- Constraint
    CONSTRAINT ck_entity_read_audit_outcome_not_empty
        CHECK (length(trim(outcome)) > 0)
);

-- ============================================================================
-- Indexes for entity_read_audit_log
-- Optimized for observability query patterns:
--   "show me reads of entity X"                     → entity_id + read_at DESC
--   "show me 404 reads spiking"                     → outcome = 'not_found'
--   "show me reads in region Y in the last hour"    → region + read_at DESC
--   "show me reads per schema for billing"          → schema_id + read_at DESC
--   "track reads by read_by"                        → read_by + read_at DESC
--   "cross-region read tracking"                    → request_origin + read_at DESC
-- ============================================================================

-- Primary lookup: all reads of a specific entity (chronological)
CREATE INDEX IF NOT EXISTS idx_read_audit_entity_id_read_at
    ON entity_read_audit_log(entity_id, read_at DESC);

-- Not-found queries: track 404 spikes for observability
CREATE INDEX IF NOT EXISTS idx_read_audit_outcome
    ON entity_read_audit_log(outcome, read_at DESC)
    WHERE outcome = 'not_found';

-- Deleted entity retrievals (access audit)
CREATE INDEX IF NOT EXISTS idx_read_audit_deleted
    ON entity_read_audit_log(is_deleted, read_at DESC)
    WHERE is_deleted = TRUE;

-- Region-based observability (cross-region read tracking)
CREATE INDEX IF NOT EXISTS idx_read_audit_region
    ON entity_read_audit_log(region, read_at DESC);

-- Schema-based aggregation (read metrics by schema type)
CREATE INDEX IF NOT EXISTS idx_read_audit_schema_id
    ON entity_read_audit_log(schema_id, read_at DESC);

-- Who-read-what audit trail
CREATE INDEX IF NOT EXISTS idx_read_audit_read_by
    ON entity_read_audit_log(read_by, read_at DESC);

-- Request origin tracking (for ResidencyContext consumer)
-- "which origins are reading entities from which regions?"
CREATE INDEX IF NOT EXISTS idx_read_audit_request_origin
    ON entity_read_audit_log(request_origin, read_at DESC);

-- Time-range queries (most common: "reads in the last hour/day")
CREATE INDEX IF NOT EXISTS idx_read_audit_read_at
    ON entity_read_audit_log(read_at DESC);

-- Composite: region + outcome + read_at (cross-region 404 analysis)
CREATE INDEX IF NOT EXISTS idx_read_audit_region_outcome
    ON entity_read_audit_log(region, outcome, read_at DESC);

-- ============================================================================
-- FUNCTION: log_entity_read()
-- Records an entity read operation to the audit log.
-- Called by the application layer after handling GET /api/v1/entities/{id}.
--
-- Gherkin mapping:
--   SCENARIO 1 (retrieved):
--     log_entity_read(entity_id='ent-abc-123', outcome='retrieved', ...)
--   SCENARIO 2 (not found):
--     log_entity_read(entity_id='ent-nonexistent', outcome='not_found', ...)
--
-- Returns the UUID of the audit log entry.
--
-- Usage:
--   PERFORM log_entity_read(
--     p_entity_id      := 'e1000001-0000-4000-8000-000000000001',
--     p_request_id     := 'req-abc-123',
--     p_outcome        := 'retrieved',
--     p_is_deleted     := FALSE,
--     p_read_by        := 'user-abc-123',
--     p_request_origin := 'api-gateway',
--     p_entity_status  := 'active',
--     p_schema_id      := 'c0000001-0000-4000-8000-000000000001',
--     p_region         := 'eu-west-1',
--     p_duration_ms    := 42
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION log_entity_read(
    p_entity_id       VARCHAR(64) DEFAULT NULL,
    p_request_id      VARCHAR(255) DEFAULT NULL,
    p_outcome         VARCHAR(32) DEFAULT 'retrieved',
    p_is_deleted      BOOLEAN DEFAULT FALSE,
    p_read_by         VARCHAR(255) DEFAULT NULL,
    p_request_origin  VARCHAR(128) DEFAULT NULL,
    p_entity_status   entity_status DEFAULT NULL,
    p_schema_id       UUID DEFAULT NULL,
    p_region          VARCHAR(64) DEFAULT NULL,
    p_duration_ms     INTEGER DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_audit_id UUID;
BEGIN
    INSERT INTO entity_read_audit_log (
        id, entity_id, request_id, outcome, is_deleted,
        read_by, request_origin, entity_status, schema_id, region,
        read_at, duration_ms
    ) VALUES (
        gen_random_uuid(),
        p_entity_id,
        p_request_id,
        p_outcome,
        p_is_deleted,
        p_read_by,
        p_request_origin,
        p_entity_status,
        p_schema_id,
        p_region,
        NOW(),
        p_duration_ms
    )
    RETURNING id INTO v_audit_id;

    RETURN v_audit_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION: enqueue_entity_read_event()
-- Enqueues an entitymanagement.entity.read CloudEvent to the outbox_events
-- table. Called within the same database transaction as the read audit log
-- insert, enabling atomic observability logging.
--
-- The application layer treats this as fire-and-forget: if enqueuing fails,
-- the error is logged but the HTTP response is still 200 with the entity
-- payload. This aligns with the Gherkin requirement:
--   "An entitymanagement.entity.read domain event is published
--    (fire-and-forget, non-blocking)"
--
-- Gherkin SCENARIO 2: This function is NOT called when the entity is not
-- found (HTTP 404), ensuring "no entity.read event is published".
--
-- Payload per Gherkin spec:
--   { event_id, entity_id, entity_name, region, read_at, request_origin }
--
-- Usage:
--   PERFORM enqueue_entity_read_event(
--     p_entity_id      := 'e1000001-0000-4000-8000-000000000001',
--     p_entity_name    := 'Alice',
--     p_region         := 'eu-west-1',
--     p_request_origin := 'api-gateway',
--     p_read_by        := 'user-abc-123'
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION enqueue_entity_read_event(
    p_entity_id       VARCHAR(64),
    p_entity_name     VARCHAR(512),
    p_region          VARCHAR(64),
    p_request_origin  VARCHAR(128) DEFAULT NULL,
    p_read_by         VARCHAR(255) DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_event_id    UUID;
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
        p_entity_id,
        'entity',
        'entitymanagement.entity.read',  -- CloudEvents type per Gherkin spec
        '/api/v1/entities',              -- Source: the HTTP endpoint serving the read
        'entity/' || p_entity_id,        -- Subject for event routing
        jsonb_build_object(
            'event_id',       v_event_id::TEXT,
            'entity_id',      p_entity_id,
            'entity_name',    p_entity_name,
            'region',         p_region,
            'read_at',        v_occurred_at,
            'request_origin', p_request_origin
        ),
        'pending',   -- Not yet processed by the outbox relay
        0,           -- Initial retry count
        NULL,        -- No error yet
        v_occurred_at
    );

    RETURN v_event_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION: get_entity_by_id_with_audit()
-- Combined atomic operation: retrieves an entity by ID AND logs the read
-- audit entry AND enqueues the entity.read event in a single function call.
--
-- This ensures the read audit is never skipped — it's part of the same
-- database transaction as the data retrieval.
--
-- Returns a structured result with:
--   found         BOOLEAN    — Whether the entity exists
--   is_deleted    BOOLEAN    — Whether the entity is soft-deleted
--   entity_json   JSONB      — Full entity payload (NULL if not found)
--   audit_id      UUID       — ID of the audit log entry
--   event_id      UUID       — ID of the enqueued entity.read event (NULL if not found)
--
-- Gherkin mapping:
--   SCENARIO 1 (retrieved):
--     found=TRUE, is_deleted=FALSE,
--     entity_json contains all attributes, schema_id, region, status,
--       version, created_at, updated_at
--     event_id is set → entity.read event enqueued
--
--   SCENARIO 2 (not found):
--     found=FALSE, entity_json=NULL, event_id=NULL (no event published)
--
-- Usage:
--   SELECT * FROM get_entity_by_id_with_audit(
--     p_entity_id      := 'e1000001-0000-4000-8000-000000000001',
--     p_request_id     := 'req-abc-123',
--     p_read_by        := 'user-abc-123',
--     p_request_origin := 'api-gateway'
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION get_entity_by_id_with_audit(
    p_entity_id       VARCHAR(64),
    p_request_id      VARCHAR(255) DEFAULT NULL,
    p_read_by         VARCHAR(255) DEFAULT NULL,
    p_request_origin  VARCHAR(128) DEFAULT NULL
)
RETURNS TABLE(
    found       BOOLEAN,
    is_deleted  BOOLEAN,
    entity_json JSONB,
    audit_id    UUID,
    event_id    UUID
) AS $$
DECLARE
    v_entity    entities%ROWTYPE;
    v_audit_id  UUID;
    v_found     BOOLEAN;
    v_deleted   BOOLEAN;
    v_json      JSONB;
    v_event_id  UUID;
    v_duration  TIMESTAMPTZ;
    v_elapsed   INTEGER;
BEGIN
    v_duration := clock_timestamp();

    -- Step 1: Fetch the entity using the existing get_entity_by_id function
    -- This handles the core retrieval, checking for existence.
    SELECT * INTO v_entity
    FROM entities e
    WHERE e.id::TEXT = p_entity_id;

    v_found   := FOUND;
    v_deleted := FALSE;

    -- Step 2: Determine outcome and build JSON payload
    IF v_found THEN
        v_deleted := (v_entity.deleted_at IS NOT NULL);

        -- Build the full entity payload per Gherkin SCENARIO 1:
        -- "Including all attributes, schema_id, region, status, version,
        --  created_at, updated_at"
        v_json := jsonb_build_object(
            'id',                 v_entity.id::TEXT,
            'schema_id',          v_entity.schema_id::TEXT,
            'schema_version',     v_entity.schema_version,
            'name',               v_entity.name,
            'type',               v_entity.type,
            'region',             v_entity.region,
            'data_residency_zone', v_entity.data_residency_zone,
            'status',             v_entity.status,
            'version',            v_entity.version,
            'attributes',         v_entity.attributes,
            'metadata',           v_entity.metadata,
            'created_at',         v_entity.created_at,
            'updated_at',         v_entity.updated_at,
            'deleted_at',         v_entity.deleted_at
        );
    ELSE
        v_json := NULL;
    END IF;

    -- Step 3: Calculate elapsed time in milliseconds (for observability metrics)
    v_elapsed := EXTRACT(MILLISECOND FROM clock_timestamp() - v_duration)::INTEGER;

    -- Step 4: Log the read audit entry
    -- SCENARIO 1: outcome='retrieved'
    -- SCENARIO 2: outcome='not_found'
    INSERT INTO entity_read_audit_log (
        id, entity_id, request_id, outcome, is_deleted,
        read_by, request_origin, entity_status, schema_id, region,
        read_at, duration_ms
    ) VALUES (
        gen_random_uuid(),
        p_entity_id,
        p_request_id,
        CASE WHEN v_found THEN 'retrieved' ELSE 'not_found' END,
        v_deleted,
        p_read_by,
        p_request_origin,
        CASE WHEN v_found THEN v_entity.status ELSE NULL END,
        CASE WHEN v_found THEN v_entity.schema_id ELSE NULL END,
        CASE WHEN v_found THEN v_entity.region ELSE NULL END,
        NOW(),
        v_elapsed
    )
    RETURNING id INTO v_audit_id;

    -- Step 5: Enqueue entity.read event ONLY for SCENARIO 1 (found entity)
    -- Gherkin: "NOT published on 404 responses"
    IF v_found THEN
        v_event_id := enqueue_entity_read_event(
            p_entity_id      := v_entity.id::TEXT,
            p_entity_name    := v_entity.name,
            p_region         := v_entity.region,
            p_request_origin := p_request_origin,
            p_read_by        := p_read_by
        );
    ELSE
        v_event_id := NULL;  -- SCENARIO 2: No event published
    END IF;

    -- Step 6: Return the structured result
    RETURN QUERY
    SELECT
        v_found     AS found,
        v_deleted   AS is_deleted,
        v_json      AS entity_json,
        v_audit_id  AS audit_id,
        v_event_id  AS event_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION: get_read_audit_trail()
-- Retrieves the read audit trail for a specific entity.
-- Useful for observability: "who read this entity, when, and from where?"
--
-- Gherkin: Used by ObservabilityContext to verify read tracking.
--
-- Usage:
--   SELECT * FROM get_read_audit_trail('e1000001-0000-4000-8000-000000000001', 10, 0);
--   SELECT * FROM get_read_audit_trail(
--     p_entity_id := 'ent-abc-123',
--     p_limit     := 5,
--     p_offset    := 0
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION get_read_audit_trail(
    p_entity_id VARCHAR(64),
    p_limit     INTEGER DEFAULT 100,
    p_offset    INTEGER DEFAULT 0
)
RETURNS TABLE(
    audit_id        UUID,
    entity_id       VARCHAR(64),
    request_id      VARCHAR(255),
    outcome         VARCHAR(32),
    is_deleted      BOOLEAN,
    read_by         VARCHAR(255),
    request_origin  VARCHAR(128),
    entity_status   entity_status,
    schema_id       UUID,
    region          VARCHAR(64),
    read_at         TIMESTAMPTZ,
    duration_ms     INTEGER
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        al.id,
        al.entity_id,
        al.request_id,
        al.outcome,
        al.is_deleted,
        al.read_by,
        al.request_origin,
        al.entity_status,
        al.schema_id,
        al.region,
        al.read_at,
        al.duration_ms
    FROM entity_read_audit_log al
    WHERE al.entity_id = p_entity_id
    ORDER BY al.read_at DESC
    LIMIT p_limit
    OFFSET p_offset;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- FUNCTION: get_read_audit_trail_by_origin()
-- Retrieves the read audit trail filtered by request origin.
-- Used by ResidencyContext consumer for cross-region read tracking.
--
-- Usage:
--   SELECT * FROM get_read_audit_trail_by_origin('api-gateway', 50, 0);
--   SELECT * FROM get_read_audit_trail_by_origin('internal-sync', 'eu-west-1', 25, 0);
-- ============================================================================
CREATE OR REPLACE FUNCTION get_read_audit_trail_by_origin(
    p_request_origin VARCHAR(128),
    p_region         VARCHAR(64) DEFAULT NULL,
    p_limit          INTEGER DEFAULT 100,
    p_offset         INTEGER DEFAULT 0
)
RETURNS TABLE(
    audit_id        UUID,
    entity_id       VARCHAR(64),
    request_id      VARCHAR(255),
    outcome         VARCHAR(32),
    is_deleted      BOOLEAN,
    read_by         VARCHAR(255),
    request_origin  VARCHAR(128),
    entity_status   entity_status,
    schema_id       UUID,
    region          VARCHAR(64),
    read_at         TIMESTAMPTZ,
    duration_ms     INTEGER
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        al.id,
        al.entity_id,
        al.request_id,
        al.outcome,
        al.is_deleted,
        al.read_by,
        al.request_origin,
        al.entity_status,
        al.schema_id,
        al.region,
        al.read_at,
        al.duration_ms
    FROM entity_read_audit_log al
    WHERE al.request_origin = p_request_origin
      AND (p_region IS NULL OR al.region = p_region)
    ORDER BY al.read_at DESC
    LIMIT p_limit
    OFFSET p_offset;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- FUNCTION: get_read_latency_percentiles()
-- Returns read latency percentiles (p50, p95, p99) aggregated by schema,
-- region, or outcome. Used by ObservabilityContext for SLO monitoring.
--
-- Percentiles are calculated using PostgreSQL's percentile_cont ordered-set
-- aggregate functions.
--
-- Usage:
--   -- Get p50/p95/p99 for all reads in the last hour
--   SELECT * FROM get_read_latency_percentiles(
--     p_time_range := '1 hour',
--     p_schema_id  := NULL,
--     p_region     := NULL,
--     p_outcome    := 'retrieved'
--   );
--
--   -- Get p50/p95/p99 for reads of schema 'Customer' in eu-west-1
--   SELECT * FROM get_read_latency_percentiles(
--     p_time_range := '24 hours',
--     p_schema_id  := 'c0000001-0000-4000-8000-000000000001',
--     p_region     := 'eu-west-1',
--     p_outcome    := NULL
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION get_read_latency_percentiles(
    p_time_range TEXT DEFAULT '1 hour',
    p_schema_id  UUID DEFAULT NULL,
    p_region     VARCHAR(64) DEFAULT NULL,
    p_outcome    VARCHAR(32) DEFAULT NULL
)
RETURNS TABLE(
    p50_ms  NUMERIC,
    p95_ms  NUMERIC,
    p99_ms  NUMERIC,
    count   BIGINT,
    schema_id UUID,
    region    VARCHAR(64),
    outcome   VARCHAR(32)
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        percentile_cont(0.50) WITHIN GROUP (ORDER BY duration_ms) AS p50_ms,
        percentile_cont(0.95) WITHIN GROUP (ORDER BY duration_ms) AS p95_ms,
        percentile_cont(0.99) WITHIN GROUP (ORDER BY duration_ms) AS p99_ms,
        COUNT(*)::BIGINT AS count,
        al.schema_id,
        al.region,
        al.outcome
    FROM entity_read_audit_log al
    WHERE al.read_at >= NOW() - p_time_range::INTERVAL
      AND (p_schema_id IS NULL OR al.schema_id = p_schema_id)
      AND (p_region IS NULL OR al.region = p_region)
      AND (p_outcome IS NULL OR al.outcome = p_outcome)
    GROUP BY GROUPING SETS (
        (al.schema_id, al.region, al.outcome),
        (al.schema_id, al.region),
        (al.schema_id, al.outcome),
        (al.region, al.outcome),
        (al.schema_id),
        (al.region),
        (al.outcome),
        ()
    )
    ORDER BY al.schema_id NULLS LAST, al.region NULLS LAST, al.outcome NULLS LAST;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- FUNCTION: prune_expired_read_audit_logs()
-- Cleans up read audit logs older than a configurable retention period.
-- Default retention is 90 days (aligned with typical observability retention).
-- Returns the number of deleted rows.
--
-- Call this periodically via pg_cron or application scheduler:
--   -- Daily cleanup at 02:00 UTC
--   SELECT cron.schedule('prune-read-audit', '0 2 * * *',
--     $$SELECT prune_expired_read_audit_logs(90);$$);
--
-- Usage:
--   SELECT prune_expired_read_audit_logs();        -- 90 days default
--   SELECT prune_expired_read_audit_logs(30);      -- 30 days custom
--   SELECT prune_expired_read_audit_logs(365);     -- 1 year for compliance
-- ============================================================================
CREATE OR REPLACE FUNCTION prune_expired_read_audit_logs(
    p_retention_days INTEGER DEFAULT 90
)
RETURNS INTEGER AS $$
DECLARE
    v_deleted INTEGER;
BEGIN
    DELETE FROM entity_read_audit_log
    WHERE read_at < NOW() - (p_retention_days || ' days')::INTERVAL;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RETURN v_deleted;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION: get_cross_region_read_summary()
-- Returns a summary of cross-region read activity for ResidencyContext.
-- Shows how many reads each region is receiving from other regions/origins.
--
-- Usage:
--   SELECT * FROM get_cross_region_read_summary('24 hours');
-- ============================================================================
CREATE OR REPLACE FUNCTION get_cross_region_read_summary(
    p_time_range TEXT DEFAULT '24 hours'
)
RETURNS TABLE(
    request_origin  VARCHAR(128),
    region          VARCHAR(64),
    read_count      BIGINT,
    avg_duration_ms NUMERIC,
    last_read_at    TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        al.request_origin,
        al.region,
        COUNT(*)::BIGINT AS read_count,
        AVG(al.duration_ms)::NUMERIC(10,2) AS avg_duration_ms,
        MAX(al.read_at) AS last_read_at
    FROM entity_read_audit_log al
    WHERE al.read_at >= NOW() - p_time_range::INTERVAL
    GROUP BY al.request_origin, al.region
    ORDER BY read_count DESC;
END;
$$ LANGUAGE plpgsql STABLE;

COMMIT;
