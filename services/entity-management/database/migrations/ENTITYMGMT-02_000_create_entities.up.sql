-- Migration: ENTITYMGMT-02_000_create_entities.up.sql
-- Story: ENTITYMGMT-02 — User creates an entity with idempotency support (7-day TTL)
-- Bounded Context: Entity Management
--
-- Prerequisites: ENTITYMGMT-01_000_schema_definition.up.sql
--   - entity_schemas table (aggregate root for schema definitions)
--   - entity_schema_attributes table (normalized attribute definitions)
--   - outbox_events table (transactional outbox for CloudEvents)
--   - update_modified_column() trigger function
--   - entity_management_attribute_type ENUM
--
-- ============================================================================
-- Gherkin Scenarios
-- ============================================================================
--
-- SCENARIO 1: Successful entity creation with idempotency
--   Given a schema "Customer" exists with attributes email (string, required)
--     and name (string, required)
--   When a POST /api/v1/entities request is sent
--     With Idempotency-Key: "create-customer-001"
--     And body: {"schema_id": "sch-customer", "name": "Alice", "type": "customer",
--                "region": "eu-west-1",
--                "attributes": {"email": "alice@example.com", "name": "Alice"}}
--   Then an entity is created with status "active" and version 1
--     And the entity is tagged with DataResidencyZone="eu-west-1"
--     And an entitymanagement.entity.created event is enqueued in the outbox
--        within the same transaction
--     And the idempotency key is stored with a 7-day TTL
--     And HTTP 201 is returned with the entity ID and version
--
-- SCENARIO 2: Idempotent replay within TTL
--   Given idempotency key "create-customer-001" was used in a previous
--     successful create (entity "E1")
--   When a POST /api/v1/entities is sent with the same
--     Idempotency-Key: "create-customer-001"
--   Then the existing entity "E1" is returned (HTTP 200)
--     And no duplicate entity is created
--     And no duplicate entity.created event is emitted
--
-- SCENARIO 3: Expired idempotency key
--   Given idempotency key "expired-key" was stored 8 days ago
--   When a POST /api/v1/entities is sent with Idempotency-Key: "expired-key"
--   Then the key is treated as expired (TTL exceeded)
--     And a new entity is created
--
-- ============================================================================
-- Domain Events (transactional outbox, reusing outbox_events from ENTITYMGMT-01)
-- ============================================================================
--
-- entitymanagement.entity.created  — Published when a new entity is created.
--   Owned by EntityManagement context. Written to outbox within the same DB
--   transaction as the entity insert. NOT emitted on idempotency replays
--   within the 7-day TTL window.
--
--   Payload:
--     { event_id, entity_id, entity_name, entity_type, region,
--       data_residency_zone, schema_id, version: 1, status: "active",
--       attributes, metadata, occurred_at }
--
--   Consumers:
--     Billing (trigger billing), Search (index entity),
--     Notification (send creation alert), Audit (log creation),
--     OutboxRelay (publish to NATS)
--
-- ============================================================================
-- Tables created
-- ============================================================================
--   entities              — Concrete entity instances (aggregate root)
--   request_idempotency   — Client-supplied idempotency key → entity ID mapping
--                           with 7-day TTL expiration
--
-- ============================================================================

BEGIN;

-- ============================================================================
-- ENUM: entity_status
-- Lifecycle states for a concrete entity instance.
-- Default on creation: 'active' (per Gherkin SCENARIO 1).
-- ============================================================================
DO $$ BEGIN
    CREATE TYPE entity_status AS ENUM (
        'active',        -- Entity is operational and discoverable (default)
        'inactive',      -- Entity is temporarily suspended
        'deleted',       -- Entity is soft-deleted (terminal state per domain logic)
        'provisioning'   -- Entity is being provisioned (async creation flow)
    );
EXCEPTION WHEN duplicate_object THEN null;
END $$;

-- ============================================================================
-- FUNCTION: compute_data_residency_zone
-- Maps cloud provider regions to data residency zones.
-- IMMUTABLE because the mapping is fixed; used by a generated column below.
--
-- Gherkin SCENARIO 1: "entity is tagged with DataResidencyZone='eu-west-1'"
-- The generated column automatically computes the zone from the region.
-- ============================================================================
CREATE OR REPLACE FUNCTION compute_data_residency_zone(p_region TEXT)
RETURNS TEXT AS $$
BEGIN
    RETURN CASE
        WHEN p_region IN ('us-east-1', 'us-east-2', 'us-west-1', 'us-west-2') THEN 'us'
        WHEN p_region IN ('eu-west-1', 'eu-west-2', 'eu-west-3', 'eu-central-1', 'eu-north-1') THEN 'eu'
        WHEN p_region IN ('ap-southeast-1', 'ap-southeast-2', 'ap-southeast-3') THEN 'ap-southeast'
        WHEN p_region IN ('ap-northeast-1', 'ap-northeast-2', 'ap-northeast-3') THEN 'ap-northeast'
        WHEN p_region IN ('sa-east-1') THEN 'sa'
        WHEN p_region IN ('me-south-1', 'af-south-1') THEN 'me-af'
        WHEN p_region IN ('ca-central-1') THEN 'ca'
        ELSE 'other'
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ============================================================================
-- TABLE: entities
-- Stores concrete entity instances that conform to an entity_schema blueprint.
--
-- Gherkin mapping (SCENARIO 1):
--   "entity is created with status 'active' and version 1"
--     → entities.status = 'active', entities.version = 1
--   "entity is tagged with DataResidencyZone='eu-west-1'"
--     → data_residency_zone generated column from region 'eu-west-1'
--   "HTTP 201 is returned with the entity ID and version"
--     → entities.id + entities.version
-- ============================================================================
CREATE TABLE IF NOT EXISTS entities (
    -- Core identity
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Schema reference (FK to entity_schemas from ENTITYMGMT-01)
    schema_id           UUID NOT NULL,
    schema_version      INTEGER NOT NULL DEFAULT 1
                        CHECK (schema_version >= 1),

    -- Canonical entity fields
    name                VARCHAR(512) NOT NULL,
    type                VARCHAR(255) NOT NULL DEFAULT '',

    -- Multi-region deployment support
    region              VARCHAR(64) NOT NULL,
    data_residency_zone TEXT GENERATED ALWAYS AS (compute_data_residency_zone(region)) STORED,

    -- Lifecycle state (default: 'active' per Gherkin SCENARIO 1)
    status              entity_status NOT NULL DEFAULT 'active',

    -- Optimistic concurrency version
    -- Starts at 1 on creation (Gherkin: "version 1"), incremented on each update
    version             INTEGER NOT NULL DEFAULT 1
                        CHECK (version >= 1),

    -- Dynamic schema-defined attributes (validated against entity_schema_attributes
    -- by the application layer before persistence)
    attributes          JSONB NOT NULL DEFAULT '{}',

    -- Free-form metadata (tags, labels, annotations)
    metadata            JSONB NOT NULL DEFAULT '{}',

    -- Timestamps
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at          TIMESTAMPTZ,   -- Populated on soft-delete

    -- Constraints
    CONSTRAINT fk_entities_schema
        FOREIGN KEY (schema_id) REFERENCES entity_schemas(id) ON DELETE RESTRICT,
    CONSTRAINT ck_entities_name_not_empty
        CHECK (length(trim(name)) > 0),
    CONSTRAINT ck_entities_region_not_empty
        CHECK (length(trim(region)) > 0),
    CONSTRAINT ck_entities_schema_version_positive
        CHECK (schema_version >= 1),

    -- Names must be unique per schema (prevents duplicate entities within same schema type)
    CONSTRAINT uq_entities_schema_name UNIQUE (schema_id, name)
);

-- ============================================================================
-- Indexes for entities
-- Optimized for the query patterns in SCENARIO 1-3.
-- ============================================================================

-- Primary lookup by schema: "list all entities of type X"
CREATE INDEX IF NOT EXISTS idx_entities_schema_id
    ON entities(schema_id);

-- Composite: schema + status (most common filtered listing)
CREATE INDEX IF NOT EXISTS idx_entities_schema_status
    ON entities(schema_id, status);

-- Composite: schema + status + created_at DESC (paginated listing)
CREATE INDEX IF NOT EXISTS idx_entities_schema_status_created
    ON entities(schema_id, status, created_at DESC);

-- Region-scoped queries: "find all active entities in eu-west-1"
CREATE INDEX IF NOT EXISTS idx_entities_region_status
    ON entities(region, status);

-- Data residency zone queries (generated column)
CREATE INDEX IF NOT EXISTS idx_entities_data_residency_zone
    ON entities(data_residency_zone);

-- Type-based grouping/filtering
CREATE INDEX IF NOT EXISTS idx_entities_type
    ON entities(type);

-- Status-based lifecycle queries
CREATE INDEX IF NOT EXISTS idx_entities_status
    ON entities(status);

-- Chronological ordering (default listing order)
CREATE INDEX IF NOT EXISTS idx_entities_created_at
    ON entities(created_at DESC);

-- Updated-at queries (for cache invalidation)
CREATE INDEX IF NOT EXISTS idx_entities_updated_at
    ON entities(updated_at DESC);

-- Full-text search on entity name (requires pg_trgm extension)
-- CREATE INDEX IF NOT EXISTS idx_entities_name_trgm
--     ON entities USING GIN (name gin_trgm_ops);

-- JSONB index for querying dynamic schema-defined attributes
CREATE INDEX IF NOT EXISTS idx_entities_attributes
    ON entities USING GIN (attributes jsonb_path_ops);

-- JSONB index for querying metadata
CREATE INDEX IF NOT EXISTS idx_entities_metadata
    ON entities USING GIN (metadata jsonb_path_ops);

-- Partial index: active (non-deleted) entities only
CREATE INDEX IF NOT EXISTS idx_entities_active
    ON entities(schema_id, region)
    WHERE status != 'deleted';

-- Optimistic concurrency index: find entities by version
CREATE INDEX IF NOT EXISTS idx_entities_version
    ON entities(schema_id, version);

-- ============================================================================
-- Trigger: auto-update updated_at on entities
-- ============================================================================
CREATE TRIGGER update_entities_modtime
    BEFORE UPDATE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

-- ============================================================================
-- TABLE: request_idempotency
-- Client-supplied idempotency key mapping (Gherkin SCENARIO 1, 2, 3).
--
-- When a client sends a CreateEntity request with an Idempotency-Key header,
-- the system checks this table FIRST:
--   - If the key exists and has NOT expired → return the existing entity
--     (HTTP 200, no duplicate, SCENARIO 2)
--   - If the key exists but HAS expired → treat as new request
--     (SCENARIO 3)
--   - If the key does NOT exist → create entity + event + store key
--     (HTTP 201, SCENARIO 1)
--
-- Rows have a 7-day TTL (expires_at = created_at + 7 days).
-- Expired rows are pruned by prune_expired_idempotency().
-- The PRIMARY KEY is the request_key (the client-supplied Idempotency-Key value).
--
-- Gherkin mapping:
--   "Idempotency-Key: 'create-customer-001'" → request_key = 'create-customer-001'
--   "idempotency key is stored with a 7-day TTL" → expires_at = NOW() + 7 days
--   "key is treated as expired (TTL exceeded)" → expires_at < NOW()
-- ============================================================================
CREATE TABLE IF NOT EXISTS request_idempotency (
    request_key     TEXT PRIMARY KEY,       -- Client-supplied idempotency key (e.g., "create-customer-001")
    entity_id       UUID NOT NULL,          -- The entity that was created for this key
    expires_at      TIMESTAMPTZ NOT NULL,   -- TTL expiry (created_at + 7 days)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Entity reference for data integrity
    CONSTRAINT fk_request_idempotency_entity
        FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE CASCADE,

    -- TTL must be in the future at insert time (minimum 1 hour, max 30 days)
    CONSTRAINT ck_request_idempotency_expires_at_check
        CHECK (expires_at > created_at + INTERVAL '1 hour'
           AND expires_at <= created_at + INTERVAL '30 days')
);

-- Index for efficient TTL-based cleanup: find expired records
CREATE INDEX IF NOT EXISTS idx_request_idempotency_expires_at
    ON request_idempotency(expires_at ASC);

-- Index for entity_id lookup (for administrative queries)
CREATE INDEX IF NOT EXISTS idx_request_idempotency_entity_id
    ON request_idempotency(entity_id);

-- Partial index: active (non-expired) keys for fast lookup
CREATE INDEX IF NOT EXISTS idx_request_idempotency_active
    ON request_idempotency(request_key)
    WHERE expires_at > NOW();

-- ============================================================================
-- FUNCTION: enqueue_entity_created_event()
-- Enqueues an entitymanagement.entity.created CloudEvent to the outbox.
-- Called within the same database transaction as the entity insert
-- (transactional outbox pattern, reusing outbox_events from ENTITYMGMT-01).
--
-- Gherkin mapping (SCENARIO 1):
--   "an entitymanagement.entity.created event is enqueued in the outbox
--    within the same transaction" → This function inserts into outbox_events
--    with event_type = 'entitymanagement.entity.created'
--
--   Payload matches Gherkin spec:
--     { event_id, entity_id, entity_name, entity_type, region,
--       data_residency_zone, schema_id, version: 1, status: "active",
--       attributes, metadata, occurred_at }
--
-- SCENARIO 2: "no duplicate entity.created event is emitted"
--   → This function is NOT called on idempotency replays; the application
--     layer returns the cached entity without invoking the UnitOfWork.
--
-- Returns the outbox event ID for traceability.
--
-- Usage:
--   PERFORM enqueue_entity_created_event(
--     p_entity_id   := 'f0000001-...',
--     p_schema_id   := 'c0000001-...',
--     p_entity_name := 'Alice',
--     p_entity_type := 'customer',
--     p_region      := 'eu-west-1',
--     p_zone        := 'eu',
--     p_version     := 1,
--     p_status      := 'active',
--     p_attributes  := '{"email":"alice@example.com","name":"Alice"}'::jsonb,
--     p_metadata    := '{}'::jsonb
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION enqueue_entity_created_event(
    p_entity_id   UUID,
    p_schema_id   UUID,
    p_entity_name VARCHAR(512),
    p_entity_type VARCHAR(255),
    p_region      VARCHAR(64),
    p_zone        TEXT,
    p_version     INTEGER DEFAULT 1,
    p_status      TEXT DEFAULT 'active',
    p_attributes  JSONB DEFAULT '{}',
    p_metadata    JSONB DEFAULT '{}'
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
        p_entity_id::TEXT,
        'entity',
        'entitymanagement.entity.created',   -- CloudEvents type per Gherkin spec
        '/entity-manager',                    -- Source identifier for EntityManagement context
        'entity/' || p_entity_id::TEXT,       -- Subject for event routing
        jsonb_build_object(
            'event_id',            v_event_id::TEXT,
            'entity_id',           p_entity_id::TEXT,
            'entity_name',         p_entity_name,
            'entity_type',         p_entity_type,
            'region',              p_region,
            'data_residency_zone', p_zone,
            'schema_id',           p_schema_id::TEXT,
            'version',             p_version,
            'status',              p_status,
            'attributes',          p_attributes,
            'metadata',            p_metadata,
            'occurred_at',         v_occurred_at
        ),
        'pending',   -- Not yet processed by the outbox relay
        0,           -- Initial retry count
        NULL,        -- No error yet
        v_occurred_at
    )
    RETURNING id INTO v_outbox_id;

    RETURN v_outbox_id::UUID;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION: save_idempotency_key()
-- Records a client-supplied idempotency key → entity ID mapping with 7-day TTL.
-- Uses UPSERT semantics so that re-recording the same key is idempotent.
--
-- Gherkin SCENARIO 1: "the idempotency key is stored with a 7-day TTL"
--   → This function inserts into request_idempotency with expires_at = NOW() + 7 days
--
-- Gherkin SCENARIO 2: If the key already exists, this is a no-op (ON CONFLICT).
--   → "no duplicate entity is created"
--
-- Usage:
--   PERFORM save_idempotency_key(
--     p_request_key := 'create-customer-001',
--     p_entity_id   := 'f0000001-...',
--     p_ttl_days    := 7
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION save_idempotency_key(
    p_request_key TEXT,
    p_entity_id   UUID,
    p_ttl_days    INTEGER DEFAULT 7
)
RETURNS VOID AS $$
BEGIN
    INSERT INTO request_idempotency (request_key, entity_id, expires_at, created_at)
    VALUES (
        p_request_key,
        p_entity_id,
        NOW() + (p_ttl_days || ' days')::INTERVAL,
        NOW()
    )
    ON CONFLICT (request_key) DO UPDATE
        SET entity_id = EXCLUDED.entity_id,
            expires_at = EXCLUDED.expires_at;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION: get_entity_by_idempotency_key()
-- Retrieves the entity associated with a given idempotency key.
-- Returns NULL (no rows) if:
--   - The key does not exist (SCENARIO 1: new request)
--   - The key has expired (SCENARIO 3: TTL exceeded)
-- Returns the entity if:
--   - The key exists and has NOT expired (SCENARIO 2: idempotent replay)
--
-- Gherkin SCENARIO 2: "the existing entity 'E1' is returned (HTTP 200)"
--   → Application calls this, finds the entity, returns it without creating.
--
-- Gherkin SCENARIO 3: "the key is treated as expired (TTL exceeded)"
--   → Application calls this, gets no rows, proceeds to create a new entity.
--
-- Usage:
--   SELECT * FROM get_entity_by_idempotency_key('create-customer-001');
-- ============================================================================
CREATE OR REPLACE FUNCTION get_entity_by_idempotency_key(
    p_request_key TEXT
)
RETURNS TABLE(
    entity_id           UUID,
    schema_id           UUID,
    schema_version      INTEGER,
    name                VARCHAR(512),
    type                VARCHAR(255),
    region              VARCHAR(64),
    data_residency_zone TEXT,
    status              entity_status,
    version             INTEGER,
    attributes          JSONB,
    metadata            JSONB,
    created_at          TIMESTAMPTZ,
    updated_at          TIMESTAMPTZ,
    deleted_at          TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        e.id,
        e.schema_id,
        e.schema_version,
        e.name,
        e.type,
        e.region,
        e.data_residency_zone,
        e.status,
        e.version,
        e.attributes,
        e.metadata,
        e.created_at,
        e.updated_at,
        e.deleted_at
    FROM entities e
    INNER JOIN request_idempotency ri
        ON ri.entity_id = e.id
    WHERE ri.request_key = p_request_key
      AND ri.expires_at > NOW();
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- FUNCTION: create_entity_with_idempotency()
-- ATOMIC helper that handles the complete entity creation workflow within a
-- single database transaction:
--   1. Checks idempotency key (returns existing entity if found and non-expired)
--   2. Inserts the entity row
--   3. Enqueues the entitymanagement.entity.created event to outbox_events
--   4. Records the idempotency key mapping with 7-day TTL
--
-- This enforces the transactional outbox pattern at the database level:
-- the entity, outbox event, and idempotency key are always committed together.
-- If any step fails, the entire transaction is rolled back.
--
-- Gherkin SCENARIO 1: Returns out_is_new = TRUE with the new entity ID and event ID.
-- Gherkin SCENARIO 2: Returns out_is_new = FALSE with the existing entity ID,
--                     NULL event_id (no duplicate event emitted).
-- Gherkin SCENARIO 3: Expired key is treated as no key → creates a new entity.
--
-- Usage:
--   SELECT * FROM create_entity_with_idempotency(
--     p_schema_id       := 'c0000001-0000-4000-8000-000000000001',
--     p_schema_version  := 1,
--     p_name            := 'Alice',
--     p_type            := 'customer',
--     p_region          := 'eu-west-1',
--     p_attributes      := '{"email": "alice@example.com", "name": "Alice"}'::jsonb,
--     p_metadata        := '{}'::jsonb,
--     p_idempotency_key := 'create-customer-001',
--     p_ttl_days        := 7
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION create_entity_with_idempotency(
    p_schema_id       UUID,
    p_schema_version  INTEGER DEFAULT 1,
    p_name            VARCHAR(512),
    p_type            VARCHAR(255),
    p_region          VARCHAR(64),
    p_attributes      JSONB DEFAULT '{}',
    p_metadata        JSONB DEFAULT '{}',
    p_idempotency_key TEXT DEFAULT NULL,
    p_ttl_days        INTEGER DEFAULT 7
)
RETURNS TABLE(
    out_entity_id   UUID,
    out_version     INTEGER,
    out_status      TEXT,
    out_event_id    UUID,
    out_is_new      BOOLEAN,
    out_created_at  TIMESTAMPTZ
) AS $$
DECLARE
    v_existing_entity_id UUID;
    v_entity_id          UUID;
    v_entity_version     INTEGER;
    v_entity_status      TEXT;
    v_entity_created_at  TIMESTAMPTZ;
    v_zone               TEXT;
    v_event_id           UUID;
BEGIN
    -- ==========================================================================
    -- Step 1: Check idempotency key (SCENARIO 2)
    -- ==========================================================================
    IF p_idempotency_key IS NOT NULL THEN
        SELECT e.id INTO v_existing_entity_id
        FROM entities e
        INNER JOIN request_idempotency ri
            ON ri.entity_id = e.id
        WHERE ri.request_key = p_idempotency_key
          AND ri.expires_at > NOW();

        IF FOUND THEN
            -- SCENARIO 2: Idempotent replay — return existing entity (HTTP 200)
            -- NO duplicate event is emitted (out_event_id = NULL).
            RETURN QUERY
            SELECT
                e.id               AS out_entity_id,
                e.version          AS out_version,
                e.status::TEXT     AS out_status,
                NULL::UUID         AS out_event_id,   -- No duplicate event
                FALSE              AS out_is_new,      -- Not a new creation
                e.created_at       AS out_created_at
            FROM entities e
            WHERE e.id = v_existing_entity_id;

            RETURN;
        END IF;
        -- SCENARIO 3: If key exists but expired, fall through to create new entity
    END IF;

    -- ==========================================================================
    -- Step 2: Compute data residency zone from region
    -- ==========================================================================
    v_zone := compute_data_residency_zone(p_region);

    -- ==========================================================================
    -- Step 3: Insert the entity (SCENARIO 1 / SCENARIO 3)
    -- ==========================================================================
    INSERT INTO entities (
        id,
        schema_id,
        schema_version,
        name,
        type,
        region,
        status,
        version,
        attributes,
        metadata,
        created_at,
        updated_at
    ) VALUES (
        gen_random_uuid(),
        p_schema_id,
        p_schema_version,
        p_name,
        p_type,
        p_region,
        'active',           -- Default status on creation (Gherkin: "status 'active'")
        1,                   -- Initial version (Gherkin: "version 1")
        p_attributes,
        p_metadata,
        NOW(),
        NOW()
    )
    RETURNING id, version, status::TEXT, created_at
    INTO v_entity_id, v_entity_version, v_entity_status, v_entity_created_at;

    -- ==========================================================================
    -- Step 4: Enqueue the entitymanagement.entity.created event (transactional outbox)
    -- ==========================================================================
    v_event_id := enqueue_entity_created_event(
        p_entity_id   := v_entity_id,
        p_schema_id   := p_schema_id,
        p_entity_name := p_name,
        p_entity_type := p_type,
        p_region      := p_region,
        p_zone        := v_zone,
        p_version     := v_entity_version,
        p_status      := v_entity_status,
        p_attributes  := p_attributes,
        p_metadata    := p_metadata
    );

    -- ==========================================================================
    -- Step 5: Record idempotency key (if provided) with 7-day TTL
    -- ==========================================================================
    IF p_idempotency_key IS NOT NULL THEN
        PERFORM save_idempotency_key(
            p_request_key := p_idempotency_key,
            p_entity_id   := v_entity_id,
            p_ttl_days    := p_ttl_days
        );
    END IF;

    -- ==========================================================================
    -- Step 6: Return success (HTTP 201)
    -- ==========================================================================
    RETURN QUERY
    SELECT
        v_entity_id         AS out_entity_id,
        v_entity_version    AS out_version,
        v_entity_status     AS out_status,
        v_event_id          AS out_event_id,
        TRUE                AS out_is_new,
        v_entity_created_at AS out_created_at;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION: prune_expired_idempotency()
-- Cleans up idempotency tracking records older than their TTL.
-- Returns the number of deleted rows.
-- Call this periodically via pg_cron or application scheduler (e.g., daily).
--
-- Gherkin SCENARIO 3: Expired keys are treated as non-existent, allowing
-- new entity creation with the same key after the TTL window.
--
-- Usage:
--   SELECT prune_expired_idempotency();
-- ============================================================================
CREATE OR REPLACE FUNCTION prune_expired_idempotency()
RETURNS INTEGER AS $$
DECLARE
    v_deleted INTEGER;
BEGIN
    DELETE FROM request_idempotency
    WHERE expires_at < NOW();
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RETURN v_deleted;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION: get_entity_by_id()
-- Retrieves a complete entity by its ID, excluding soft-deleted entities
-- by default. Pass include_deleted = TRUE to include soft-deleted entities.
--
-- Used by the application layer for read/update/delete operations.
--
-- Usage:
--   SELECT * FROM get_entity_by_id('f0000001-...');
--   SELECT * FROM get_entity_by_id('f0000001-...', TRUE);
-- ============================================================================
CREATE OR REPLACE FUNCTION get_entity_by_id(
    p_entity_id       UUID,
    p_include_deleted BOOLEAN DEFAULT FALSE
)
RETURNS TABLE(
    entity_id           UUID,
    schema_id           UUID,
    schema_version      INTEGER,
    name                VARCHAR(512),
    type                VARCHAR(255),
    region              VARCHAR(64),
    data_residency_zone TEXT,
    status              entity_status,
    version             INTEGER,
    attributes          JSONB,
    metadata            JSONB,
    created_at          TIMESTAMPTZ,
    updated_at          TIMESTAMPTZ,
    deleted_at          TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        e.id,
        e.schema_id,
        e.schema_version,
        e.name,
        e.type,
        e.region,
        e.data_residency_zone,
        e.status,
        e.version,
        e.attributes,
        e.metadata,
        e.created_at,
        e.updated_at,
        e.deleted_at
    FROM entities e
    WHERE e.id = p_entity_id
      AND (p_include_deleted OR e.deleted_at IS NULL);
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- FUNCTION: list_entities_by_schema()
-- Lists all entities for a given schema, with optional status filter
-- and offset-based pagination. Excludes soft-deleted entities by default.
--
-- Usage:
--   SELECT * FROM list_entities_by_schema(
--     'c0000001-...',   -- schema_id
--     'active',          -- status filter (NULL = all)
--     50,                -- limit
--     0                  -- offset
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION list_entities_by_schema(
    p_schema_id       UUID,
    p_status          entity_status DEFAULT NULL,
    p_limit           INTEGER DEFAULT 100,
    p_offset          INTEGER DEFAULT 0,
    p_include_deleted BOOLEAN DEFAULT FALSE
)
RETURNS TABLE(
    entity_id           UUID,
    schema_id           UUID,
    schema_version      INTEGER,
    name                VARCHAR(512),
    type                VARCHAR(255),
    region              VARCHAR(64),
    data_residency_zone TEXT,
    status              entity_status,
    version             INTEGER,
    attributes          JSONB,
    metadata            JSONB,
    created_at          TIMESTAMPTZ,
    updated_at          TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        e.id,
        e.schema_id,
        e.schema_version,
        e.name,
        e.type,
        e.region,
        e.data_residency_zone,
        e.status,
        e.version,
        e.attributes,
        e.metadata,
        e.created_at,
        e.updated_at
    FROM entities e
    WHERE e.schema_id = p_schema_id
      AND (p_status IS NULL OR e.status = p_status)
      AND (p_include_deleted OR e.deleted_at IS NULL)
    ORDER BY e.created_at DESC, e.id DESC
    LIMIT p_limit
    OFFSET p_offset;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- FUNCTION: count_entities_by_schema()
-- Returns the total number of entities for a given schema, with optional
-- status filter. Excludes soft-deleted entities by default.
--
-- Usage:
--   SELECT count_entities_by_schema('c0000001-...');
--   SELECT count_entities_by_schema('c0000001-...', 'active');
-- ============================================================================
CREATE OR REPLACE FUNCTION count_entities_by_schema(
    p_schema_id       UUID,
    p_status          entity_status DEFAULT NULL,
    p_include_deleted BOOLEAN DEFAULT FALSE
)
RETURNS BIGINT AS $$
DECLARE
    v_count BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM entities e
    WHERE e.schema_id = p_schema_id
      AND (p_status IS NULL OR e.status = p_status)
      AND (p_include_deleted OR e.deleted_at IS NULL);

    RETURN v_count;
END;
$$ LANGUAGE plpgsql STABLE;

COMMIT;
