-- Migration: ENTITYMGMT-01_000_schema_definition.up.sql
-- Story: ENTITYMGMT-01 — Admin defines an entity schema with typed attributes
-- Bounded Context: Entity Management
--
-- ============================================================================
-- Gherkin Scenarios
-- ============================================================================
--
-- SCENARIO 1: Admin defines "Customer" schema with all supported types
--   Given the system is initialized with empty schema registry
--   When an admin defines an entity schema named "Customer"
--     And includes attributes with all supported types:
--       | name     | type   | required | constraint          |
--       | email    | string | true     | pattern=^[^@]+@[^@]+$ |
--       | age      | int    | false    | min=0 max=150       |
--       | isActive | bool   | false    |                     |
--       | status   | enum   | true     | enum=[active,inactive] |
--       | metadata | map    | false    |                     |
--       | config   | json   | false    |                     |
--   Then the schema is stored with a unique schema ID and version 1
--     And an entitymanagement.schema.defined CloudEvent is written
--     to the transactional outbox
--
-- SCENARIO 2: Duplicate schema name is rejected
--   Given a schema named "Customer" already exists
--   When an admin attempts to define another schema with the same name
--   Then the operation fails with ErrSchemaAlreadyExists
--     And no schema.defined event is emitted
--
-- ============================================================================
-- Domain Events (transactional outbox, per ADR-002)
-- ============================================================================
--
-- entitymanagement.schema.defined  — Published when a new entity schema is
--   successfully defined with typed attributes. Owned by EntityManagement context.
--   Payload: { event_id, schema_id, schema_name, version: 1,
--              attributes: [{name, type, required, constraint}], occurred_at }
--   Consumers: ValidatorCache (compile schema rules),
--              ResidencyContext (tag schema region),
--              Monitoring (schema creation audit trail)
--
-- ============================================================================
-- Tables
-- ============================================================================
--   entity_schemas            — Schema definitions (aggregate root)
--   entity_schema_attributes  — Typed attributes per schema version (normalized)
--   outbox_events             — Transactional outbox for CloudEvents (shared with ENTITY-02+)
--
-- ============================================================================

BEGIN;

-- ============================================================================
-- Prerequisite helper: updated_at trigger (idempotent)
-- ============================================================================
CREATE OR REPLACE FUNCTION update_modified_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE 'plpgsql';

-- ============================================================================
-- ENUM: entity_management_attribute_type
-- Maps one-to-one with domain.AttributeType from internal/domain/types.go.
-- All six types from the Gherkin spec are supported: string, int, bool,
-- enum, map, json.
-- ============================================================================
DO $$ BEGIN
    CREATE TYPE entity_management_attribute_type AS ENUM (
        'string',  -- Text with optional pattern, min_length, max_length
        'int',     -- Integer with optional min, max (Gherkin: "int")
        'bool',    -- Boolean true/false (Gherkin: "bool")
        'enum',    -- Fixed set of string values (Gherkin: "enum")
        'map',     -- Arbitrary key-value pairs (Gherkin: "map")
        'json'     -- Arbitrary JSON structure (Gherkin: "json")
    );
EXCEPTION WHEN duplicate_object THEN null;
END $$;

-- ============================================================================
-- TABLE: entity_schemas
-- Aggregate root for entity schema definitions.
-- Each row represents a unique schema name at a specific version.
--
-- Gherkin mapping (SCENARIO 1):
--   "unique schema ID"          → entity_schemas.id (UUID v4)
--   "version 1"                 → entity_schemas.version = 1
--   "schema named Customer"     → entity_schemas.name = 'Customer'
--
-- Gherkin mapping (SCENARIO 2):
--   "schema named Customer already exists" →
--     UNIQUE constraint on name enforces single active schema per name;
--     application layer returns ErrSchemaAlreadyExists before insert
-- ============================================================================
CREATE TABLE IF NOT EXISTS entity_schemas (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            VARCHAR(255) NOT NULL,

    -- Version number starts at 1 and increments on schema evolution.
    -- CURRENTLY: only version 1 is supported (SCENARIO 1).
    -- Future stories will support schema evolution with version bumps.
    version         INTEGER NOT NULL DEFAULT 1 CHECK (version >= 1),

    -- Schema lifecycle status
    status          VARCHAR(32) NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'inactive', 'deprecated')),

    -- Who created this schema (nullable for system-internal schemas)
    created_by      VARCHAR(255),

    -- Timestamps
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- SCENARIO 2 enforcement: unique schema name (within active schemas)
    -- A name can appear only once. To "redefine" a schema, the application
    -- layer increments the version on the existing row.
    --
    -- The application domain logic (internal/domain/service.go) checks for
    -- existing schema by name BEFORE calling Save(). If a schema with the
    -- given name exists, it increments version rather than creating a new row.
    -- However, the UNIQUE constraint below provides database-level defense:
    -- if the application layer fails to check, the DB will reject duplicates.
    CONSTRAINT uq_entity_schemas_name UNIQUE (name),

    -- Schema name must be non-empty and trimmed
    CONSTRAINT ck_entity_schemas_name_not_empty
        CHECK (length(trim(name)) > 0)
);

-- ============================================================================
-- Indexes for entity_schemas
-- ============================================================================

-- Fast lookup by name (SCENARIO 1: check for existing schema)
CREATE INDEX IF NOT EXISTS idx_entity_schemas_name
    ON entity_schemas(name);

-- Fast lookup by status (filtering active/inactive/deprecated)
CREATE INDEX IF NOT EXISTS idx_entity_schemas_status
    ON entity_schemas(status);

-- Chronological queries (audit trail, monitoring)
CREATE INDEX IF NOT EXISTS idx_entity_schemas_created_at
    ON entity_schemas(created_at DESC);

-- Version-based queries (find latest version)
CREATE INDEX IF NOT EXISTS idx_entity_schemas_name_version
    ON entity_schemas(name, version DESC);

-- Who created what (audit trail)
CREATE INDEX IF NOT EXISTS idx_entity_schemas_created_by
    ON entity_schemas(created_by);

-- ============================================================================
-- Trigger: auto-update updated_at
-- ============================================================================
CREATE TRIGGER update_entity_schemas_modtime
    BEFORE UPDATE ON entity_schemas
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

-- ============================================================================
-- TABLE: entity_schema_attributes
-- Normalized storage for typed attributes that make up a schema definition.
--
-- This is the normalized form of domain.AttributeDefinition[].
-- Each row represents a single attribute with its name, type, required flag,
-- and optional constraint configuration.
--
-- Gherkin mapping (SCENARIO 1 — Customer attributes):
--   | email    | string | true  | pattern=^[^@]+@[^@]+$    |
--   | age      | int    | false | min=0 max=150             |
--   | isActive | bool   | false |                           |
--   | status   | enum   | true  | enum=[active,inactive]    |
--   | metadata | map    | false |                           |
--   | config   | json   | false |                           |
--
-- Constraint storage (JSONB):
--   string: { "pattern": "^[^@]+@[^@]+$" }
--   int:    { "min": 0, "max": 150 }
--   bool:   {}
--   enum:   { "enum": ["active", "inactive"] }
--   map:    {}
--   json:   {}
-- ============================================================================
CREATE TABLE IF NOT EXISTS entity_schema_attributes (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- FK to entity_schemas (cascade delete: removing schema removes attrs)
    schema_id       UUID NOT NULL REFERENCES entity_schemas(id) ON DELETE CASCADE,

    -- Attribute name (e.g., "email", "age", "isActive")
    name            VARCHAR(255) NOT NULL,

    -- Attribute type (maps to domain.AttributeType enum)
    attr_type       entity_management_attribute_type NOT NULL,

    -- Whether this attribute is required during entity creation
    required        BOOLEAN NOT NULL DEFAULT FALSE,

    -- Optional validation constraints, stored as JSONB.
    -- Structure varies by type (see examples above).
    -- Default is empty object '{}' for types with no constraints.
    constraints     JSONB NOT NULL DEFAULT '{}',

    -- Ordinal position of the attribute within the schema definition
    ordinal         INTEGER NOT NULL DEFAULT 0,

    -- Timestamp
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Attribute names must be unique within a schema
    CONSTRAINT uq_entity_schema_attributes_schema_name
        UNIQUE (schema_id, name),

    -- Ordinal positions must be unique within a schema
    CONSTRAINT uq_entity_schema_attributes_ordinal
        UNIQUE (schema_id, ordinal),

    -- Attribute name must be non-empty
    CONSTRAINT ck_entity_schema_attributes_name_not_empty
        CHECK (length(trim(name)) > 0),

    -- Ordinal must be non-negative
    CONSTRAINT ck_entity_schema_attributes_ordinal_positive
        CHECK (ordinal >= 0)
);

-- ============================================================================
-- Indexes for entity_schema_attributes
-- ============================================================================

-- Primary lookup: all attributes for a schema, ordered by ordinal
CREATE INDEX IF NOT EXISTS idx_entity_schema_attributes_schema_id
    ON entity_schema_attributes(schema_id, ordinal);

-- Type-based queries: "find all schemas with an enum attribute"
CREATE INDEX IF NOT EXISTS idx_entity_schema_attributes_type
    ON entity_schema_attributes(attr_type);

-- Required-attribute queries: "find all required attributes"
CREATE INDEX IF NOT EXISTS idx_entity_schema_attributes_required
    ON entity_schema_attributes(schema_id, required);

-- ============================================================================
-- TABLE: outbox_events
-- Transactional outbox for CloudEvents (per ADR-002).
-- This table stores domain events that need to be published to the message
-- broker. Events are inserted atomically within the same database transaction
-- as the business data write, ensuring at-least-once delivery.
--
-- The outbox relay (a background process) polls this table for unprocessed
-- events, publishes them to NATS/Kafka, and marks them as published.
--
-- Gherkin mapping (SCENARIO 1):
--   "an entitymanagement.schema.defined CloudEvent is written
--    to the transactional outbox" →
--     INSERT INTO outbox_events (event_type, source, subject, data, ...)
--     VALUES ('entitymanagement.schema.defined', '/entity-manager',
--             'schema/<schema_id>', '{...}', ...)
--
-- This table follows the same schema as the existing outbox_events table
-- used by the postgres adapter (see internal/adapters/postgres/postgres_repo.go).
-- ============================================================================
CREATE TABLE IF NOT EXISTS outbox_events (
    id              TEXT PRIMARY KEY DEFAULT gen_random_uuid()::TEXT,
    event_id        TEXT NOT NULL,             -- UUID v4 for event deduplication

    -- Aggregate identifiers for routing and correlation
    aggregate_id    TEXT,                      -- ID of the aggregate that emitted the event
    aggregate_type  TEXT,                      -- Type of aggregate (e.g., 'schema', 'entity')

    -- CloudEvents-compliant fields
    event_type      TEXT NOT NULL,             -- CloudEvents type (e.g., 'entitymanagement.schema.defined')
    source          TEXT NOT NULL DEFAULT '/entity-manager',  -- CloudEvents source
    subject         TEXT,                      -- CloudEvents subject (e.g., 'schema/<schema_id>')

    -- Event payload (CloudEvents data attribute)
    payload         JSONB NOT NULL,

    -- Delivery tracking
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'published', 'failed')),
    retry_count     INTEGER NOT NULL DEFAULT 0,
    last_error      TEXT,

    -- Timestamps
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Idempotency: prevent duplicate event processing
    CONSTRAINT uq_outbox_events_event_id UNIQUE (event_id)
);

-- ============================================================================
-- Indexes for outbox_events
-- ============================================================================

-- Primary relay query: fetch oldest unprocessed pending events
CREATE INDEX IF NOT EXISTS idx_outbox_pending_events
    ON outbox_events(created_at ASC, retry_count ASC)
    WHERE status = 'pending';

-- Event type filtering (e.g., "find all schema.defined events")
CREATE INDEX IF NOT EXISTS idx_outbox_event_type
    ON outbox_events(event_type);

-- Event deduplication lookup
CREATE INDEX IF NOT EXISTS idx_outbox_event_id
    ON outbox_events(event_id);

-- Subject-based routing lookup
CREATE INDEX IF NOT EXISTS idx_outbox_subject
    ON outbox_events(subject);

-- Aggregate-based lookup: "find all events for this aggregate"
CREATE INDEX IF NOT EXISTS idx_outbox_aggregate
    ON outbox_events(aggregate_type, aggregate_id);

-- Chronological queries
CREATE INDEX IF NOT EXISTS idx_outbox_created_at
    ON outbox_events(created_at DESC);

-- Failed events for DLQ processing
CREATE INDEX IF NOT EXISTS idx_outbox_failed
    ON outbox_events(retry_count DESC, created_at ASC)
    WHERE status = 'failed';

-- ============================================================================
-- FUNCTION: enqueue_schema_defined_event()
-- Enqueues an entitymanagement.schema.defined CloudEvent to the outbox.
-- Called by the application layer after successfully persisting a schema,
-- within the same database transaction (transactional outbox pattern).
--
-- Gherkin mapping (SCENARIO 1):
--   "an entitymanagement.schema.defined CloudEvent is written
--    to the transactional outbox" → This function inserts the event.
--
-- Returns the outbox event ID for traceability.
--
-- Usage:
--   PERFORM enqueue_schema_defined_event(
--     p_schema_id   := 'f0000001-0000-4000-8000-000000000001',
--     p_schema_name := 'Customer',
--     p_version     := 1,
--     p_created_by  := 'admin@example.com'
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION enqueue_schema_defined_event(
    p_schema_id   UUID,
    p_schema_name VARCHAR(255),
    p_version     INTEGER DEFAULT 1,
    p_created_by  VARCHAR(255) DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_event_id    UUID;
    v_outbox_id   TEXT;
    v_occurred_at TIMESTAMPTZ;
    v_attributes  JSONB;
BEGIN
    v_event_id    := gen_random_uuid();
    v_occurred_at := NOW();

    -- Build the attributes array from the schema's attribute definitions
    SELECT jsonb_agg(
        jsonb_build_object(
            'name',       esa.name,
            'type',       esa.attr_type,
            'required',   esa.required,
            'constraint', esa.constraints
        ) ORDER BY esa.ordinal
    )
    INTO v_attributes
    FROM entity_schema_attributes esa
    WHERE esa.schema_id = p_schema_id;

    -- Insert the outbox event
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
        p_schema_id::TEXT,
        'schema',
        'entitymanagement.schema.defined',  -- CloudEvents type per Gherkin spec
        '/entity-manager',                  -- Source identifier for this bounded context
        'schema/' || p_schema_id::TEXT,     -- Subject for event routing
        jsonb_build_object(
            'event_id',    v_event_id::TEXT,
            'schema_id',   p_schema_id::TEXT,
            'schema_name', p_schema_name,
            'version',     p_version,
            'attributes',  COALESCE(v_attributes, '[]'::jsonb),
            'created_by',  p_created_by,
            'occurred_at', v_occurred_at
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
-- FUNCTION: define_schema_with_attributes()
-- Atomic helper that creates a schema AND its attributes AND enqueues the
-- schema.defined event in a single database transaction.
--
-- This function enforces the transactional outbox pattern at the database
-- level: the schema, attributes, and outbox event are always committed
-- together. If any step fails, the entire transaction is rolled back.
--
-- SCENARIO 1: Returns the schema ID, version, and event ID.
-- SCENARIO 2: If a schema with the same name already exists (and is active),
--             the function returns NULL for schema_id and sets
--             out_schema_id = NULL, indicating the caller should return
--             ErrSchemaAlreadyExists.
--
-- Usage:
--   SELECT * FROM define_schema_with_attributes(
--     p_name        := 'Customer',
--     p_attributes  := '[
--       {"name":"email","type":"string","required":true,"constraints":{"pattern":"^[^@]+@[^@]+$"}},
--       {"name":"age","type":"int","required":false,"constraints":{"min":0,"max":150}},
--       {"name":"isActive","type":"bool","required":false,"constraints":{}},
--       {"name":"status","type":"enum","required":true,"constraints":{"enum":["active","inactive"]}},
--       {"name":"metadata","type":"map","required":false,"constraints":{}},
--       {"name":"config","type":"json","required":false,"constraints":{}}
--     ]'::jsonb,
--     p_created_by  := 'admin@example.com'
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION define_schema_with_attributes(
    p_name        VARCHAR(255),
    p_attributes  JSONB,          -- Array of {name, type, required, constraints}
    p_created_by  VARCHAR(255) DEFAULT NULL
)
RETURNS TABLE(
    out_schema_id   UUID,
    out_name        VARCHAR(255),
    out_version     INTEGER,
    out_event_id    UUID,
    out_is_new      BOOLEAN
) AS $$
DECLARE
    v_schema_id   UUID;
    v_version     INTEGER;
    v_event_id    UUID;
    v_existing_id UUID;
    v_attr        JSONB;
    v_attr_name   VARCHAR(255);
    v_attr_type   TEXT;
    v_attr_required BOOLEAN;
    v_attr_constraints JSONB;
    v_ordinal     INTEGER := 0;
BEGIN
    -- Step 1: Check if schema already exists (SCENARIO 2 check)
    SELECT id INTO v_existing_id
    FROM entity_schemas
    WHERE name = p_name AND status = 'active';

    IF FOUND THEN
        -- Schema already exists — return NULL to indicate ErrSchemaAlreadyExists
        RETURN QUERY SELECT
            NULL::UUID AS out_schema_id,
            p_name AS out_name,
            NULL::INTEGER AS out_version,
            NULL::UUID AS out_event_id,
            FALSE AS out_is_new;
        RETURN;
    END IF;

    -- Step 2: Insert the schema (SCENARIO 1)
    INSERT INTO entity_schemas (id, name, version, status, created_by, created_at, updated_at)
    VALUES (
        gen_random_uuid(),
        p_name,
        1,           -- Initial version (per SCENARIO 1: "version 1")
        'active',
        p_created_by,
        NOW(),
        NOW()
    )
    RETURNING id, version INTO v_schema_id, v_version;

    -- Step 3: Insert each attribute
    FOR v_attr IN SELECT * FROM jsonb_array_elements(p_attributes)
    LOOP
        v_attr_name      := v_attr->>'name';
        v_attr_type      := v_attr->>'type';
        v_attr_required  := COALESCE((v_attr->>'required')::BOOLEAN, FALSE);
        v_attr_constraints := COALESCE(v_attr->'constraints', '{}'::jsonb);

        INSERT INTO entity_schema_attributes (
            id, schema_id, name, attr_type, required,
            constraints, ordinal, created_at
        ) VALUES (
            gen_random_uuid(),
            v_schema_id,
            v_attr_name,
            v_attr_type::entity_management_attribute_type,
            v_attr_required,
            v_attr_constraints,
            v_ordinal,
            NOW()
        );

        v_ordinal := v_ordinal + 1;
    END LOOP;

    -- Step 4: Enqueue the schema.defined event (transactional outbox)
    SELECT enqueue_schema_defined_event(
        p_schema_id   := v_schema_id,
        p_schema_name := p_name,
        p_version     := v_version,
        p_created_by  := p_created_by
    ) INTO v_event_id;

    -- Step 5: Return success
    RETURN QUERY SELECT
        v_schema_id AS out_schema_id,
        p_name AS out_name,
        v_version AS out_version,
        v_event_id AS out_event_id,
        TRUE AS out_is_new;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION: get_schema_with_attributes()
-- Retrieves a complete schema definition including all its attributes
-- ordered by ordinal position. Returns the schema + attributes as a
-- structured result set.
--
-- Usage:
--   SELECT * FROM get_schema_with_attributes('f0000001-0000-4000-8000-000000000001');
--
-- Returns columns:
--   schema_id, schema_name, schema_version, schema_status, schema_created_by,
--   attributes (JSONB array), created_at, updated_at
-- ============================================================================
CREATE OR REPLACE FUNCTION get_schema_with_attributes(
    p_schema_id UUID
)
RETURNS TABLE(
    schema_id       UUID,
    schema_name     VARCHAR(255),
    schema_version  INTEGER,
    schema_status   VARCHAR(32),
    schema_created_by VARCHAR(255),
    attributes      JSONB,
    created_at      TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        s.id,
        s.name,
        s.version,
        s.status,
        s.created_by,
        COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'name',        a.name,
                    'type',        a.attr_type,
                    'required',    a.required,
                    'constraint',  a.constraints
                ) ORDER BY a.ordinal
            )
            FROM entity_schema_attributes a
            WHERE a.schema_id = s.id
        ), '[]'::jsonb) AS attributes,
        s.created_at,
        s.updated_at
    FROM entity_schemas s
    WHERE s.id = p_schema_id;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- FUNCTION: find_schema_by_name()
 -- Returns the latest active version of a schema by name.
-- Returns NULL (no rows) if the schema does not exist.
--
-- Usage:
--   SELECT * FROM find_schema_by_name('Customer');
-- ============================================================================
CREATE OR REPLACE FUNCTION find_schema_by_name(
    p_schema_name VARCHAR(255)
)
RETURNS TABLE(
    schema_id       UUID,
    schema_name     VARCHAR(255),
    schema_version  INTEGER,
    schema_status   VARCHAR(32),
    attributes      JSONB,
    created_at      TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        s.id,
        s.name,
        s.version,
        s.status,
        COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'name',        a.name,
                    'type',        a.attr_type,
                    'required',    a.required,
                    'constraint',  a.constraints
                ) ORDER BY a.ordinal
            )
            FROM entity_schema_attributes a
            WHERE a.schema_id = s.id
        ), '[]'::jsonb) AS attributes,
        s.created_at,
        s.updated_at
    FROM entity_schemas s
    WHERE s.name = p_schema_name
      AND s.status = 'active'
    ORDER BY s.version DESC
    LIMIT 1;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- FUNCTION: list_all_schemas()
-- Returns all active schemas (latest version of each) with their attributes.
--
-- Usage:
--   SELECT * FROM list_all_schemas();
-- ============================================================================
CREATE OR REPLACE FUNCTION list_all_schemas()
RETURNS TABLE(
    schema_id       UUID,
    schema_name     VARCHAR(255),
    schema_version  INTEGER,
    schema_status   VARCHAR(32),
    attribute_count BIGINT,
    attributes      JSONB,
    created_at      TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        s.id,
        s.name,
        s.version,
        s.status,
        (SELECT COUNT(*) FROM entity_schema_attributes a WHERE a.schema_id = s.id) AS attribute_count,
        COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'name',        a.name,
                    'type',        a.attr_type,
                    'required',    a.required,
                    'constraint',  a.constraints
                ) ORDER BY a.ordinal
            )
            FROM entity_schema_attributes a
            WHERE a.schema_id = s.id
        ), '[]'::jsonb) AS attributes,
        s.created_at,
        s.updated_at
    FROM entity_schemas s
    WHERE s.status = 'active'
    ORDER BY s.name;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- FUNCTION: schema_exists()
-- Returns TRUE if a schema with the given name exists and is active.
-- Used by the application layer to check for ErrSchemaAlreadyExists
-- before attempting to create a new schema (SCENARIO 2).
--
-- Usage:
--   SELECT schema_exists('Customer');
-- ============================================================================
CREATE OR REPLACE FUNCTION schema_exists(
    p_schema_name VARCHAR(255)
)
RETURNS BOOLEAN AS $$
DECLARE
    v_exists BOOLEAN;
BEGIN
    SELECT EXISTS(
        SELECT 1
        FROM entity_schemas
        WHERE name = p_schema_name
          AND status = 'active'
    ) INTO v_exists;

    RETURN v_exists;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- FUNCTION: count_schema_attributes()
-- Returns the number of attributes defined for a given schema.
-- Useful for validation: schemas must have at least one attribute.
--
-- Usage:
--   SELECT count_schema_attributes('f0000001-0000-4000-8000-000000000001');
-- ============================================================================
CREATE OR REPLACE FUNCTION count_schema_attributes(
    p_schema_id UUID
)
RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM entity_schema_attributes
    WHERE schema_id = p_schema_id;

    RETURN v_count;
END;
$$ LANGUAGE plpgsql STABLE;

COMMIT;
