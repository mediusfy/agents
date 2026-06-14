-- Migration: 002_create_entity_schemas.sql
-- Story: ENT-01: Define Entity Schema with typed fields and validation rules
--
-- Gherkin Scenarios:
--   SCENARIO 1: Successfully define a new entity schema
--     Given a platform engineer submits a schema definition with field types
--     (string, int, bool, json) and validation rules (required, min, max, pattern)
--     When the schema is persisted
--     Then the schema is assigned a unique schema ID and version number
--     And the schema is available for entity creation
--
--   SCENARIO 2: Reject schema with unsupported field type
--     Given a platform engineer submits a schema with an unsupported field type
--     When the schema is validated
--     Then the request is rejected with a 400 Bad Request error
--     And the error message identifies the unsupported type
--
-- Domain Events (transactional outbox pattern, per ADR-002):
--   schema.SchemaDefined           — Fires after a valid schema is persisted
--   schema.SchemaValidationFailed  — Fires when schema validation fails
--
-- ============================================================================
-- Bounded Context: Entity Management
-- Tables:
--   entity_schemas              — Core schema definitions (entity blueprints)
--   entity_schema_fields        — Typed attributes/fields of each schema version
--   entity_schema_versions      — Immutable version history for audit trail
--   schema_validation_failures  — Log of schema validation failures (SchemaValidationFailed)
--   event_outbox                — Transactional outbox for domain event publishing
-- ============================================================================

-- ============================================================================
-- UP
-- ============================================================================

-- ============================================================================
-- Helper: updated_at trigger (idempotent — safe to re-run)
-- ============================================================================
CREATE OR REPLACE FUNCTION update_modified_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

-- ============================================================================
-- Enum: entity_schema_status
-- Represents the lifecycle state of a schema definition.
-- ============================================================================
DO $$ BEGIN
    CREATE TYPE entity_schema_status AS ENUM (
        'active',
        'inactive',
        'deprecated'
    );
EXCEPTION WHEN duplicate_object THEN null;
END $$;

-- ============================================================================
-- Enum: entity_field_type
-- Gherkin-specified types: string, int, bool, json
-- Extended for real-world use: number, enum, map, array, date, datetime,
-- uuid, email, url
--
-- When the platform engineer submits a field type NOT in this enum, the
-- system rejects with 400 Bad Request (SchemaValidationFailed event).
-- ============================================================================
DO $$ BEGIN
    CREATE TYPE entity_field_type AS ENUM (
        -- Gherkin-specified types (SCENARIO 1)
        'string',   -- Text values with optional min_length, max_length, pattern
        'integer',  -- Integer numeric values with optional min, max (Gherkin: "int")
        'boolean',  -- True/false values (Gherkin: "bool")
        'json',     -- Arbitrary JSON values (Gherkin: "json")

        -- Extended types for real-world entity management
        'number',   -- Floating-point numeric values with optional min, max
        'enum',     -- Fixed set of string values: { "values": ["a", "b"] }
        'map',      -- Key-value pairs: { "key_type": "string", "value_type": "string" }
        'array',    -- Ordered collection: { "item_type": "string", "max_items": 10 }
        'date',     -- ISO 8601 date (YYYY-MM-DD)
        'datetime', -- ISO 8601 datetime with timezone
        'uuid',     -- Universally Unique Identifier (v4/v7)
        'email',    -- Email address with format validation
        'url'       -- URL with format validation
    );
EXCEPTION WHEN duplicate_object THEN null;
END $$;

-- ============================================================================
-- Helper: is_supported_field_type
-- Validates that a field type string is a member of the entity_field_type enum.
-- Used by application validation layer and can be called directly for
-- database-level validation.
--
-- Returns TRUE if the type is supported, FALSE otherwise.
-- ============================================================================
CREATE OR REPLACE FUNCTION is_supported_field_type(p_type TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    PERFORM p_type::entity_field_type;
    RETURN TRUE;
EXCEPTION WHEN invalid_text_representation THEN
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ============================================================================
-- Table: entity_schemas
-- Core blueprint/definition for dynamic entity types.
--
-- Gherkin mapping (SCENARIO 1):
--   "schema is assigned a unique schema ID"   → entity_schemas.id (UUID)
--   "schema is assigned a ... version number"  → entity_schemas.version
--   "schema is available for entity creation"  → status = 'active'
-- ============================================================================
CREATE TABLE IF NOT EXISTS entity_schemas (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            VARCHAR(255) NOT NULL,
    slug            VARCHAR(255) NOT NULL,
    version         INTEGER NOT NULL DEFAULT 1,
    description     TEXT,
    status          entity_schema_status NOT NULL DEFAULT 'active',
    created_by      UUID,  -- FK to users table (added when users table exists)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- A schema name + version combo must be unique (supports versioning)
    CONSTRAINT uq_entity_schemas_name_version UNIQUE (name, version),

    -- Slug must be unique among non-deprecated schemas
    CONSTRAINT uq_entity_schemas_slug UNIQUE (slug)
);

-- Partial unique index: enforce unique slug only for active schemas
-- (deprecated schemas can share a slug with their replacement)
CREATE UNIQUE INDEX IF NOT EXISTS uq_entity_schemas_slug_active
    ON entity_schemas(slug)
    WHERE status != 'deprecated';

-- Indexes for query performance
CREATE INDEX IF NOT EXISTS idx_entity_schemas_status ON entity_schemas(status);
CREATE INDEX IF NOT EXISTS idx_entity_schemas_created_by ON entity_schemas(created_by);
CREATE INDEX IF NOT EXISTS idx_entity_schemas_name ON entity_schemas(name);
CREATE INDEX IF NOT EXISTS idx_entity_schemas_name_version ON entity_schemas(name, version DESC);
CREATE INDEX IF NOT EXISTS idx_entity_schemas_created_at ON entity_schemas(created_at DESC);

-- Trigger: auto-update updated_at
CREATE TRIGGER update_entity_schemas_modtime
    BEFORE UPDATE ON entity_schemas
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

-- ============================================================================
-- Table: entity_schema_fields
-- Stores the typed attributes/fields that make up a schema definition.
-- Each field belongs to a schema version and defines its type and constraints.
--
-- Gherkin mapping (SCENARIO 1):
--   "field types (string, int, bool, json)"  → entity_schema_fields.field_type
--   "validation rules (required, min, max, pattern)" → entity_schema_fields.constraints
--     • required  → entity_schema_fields.required BOOLEAN
--     • min       → constraints->'minimum' / constraints->'min_length'
--     • max       → constraints->'maximum' / constraints->'max_length'
--     • pattern   → constraints->'pattern'
-- ============================================================================
CREATE TABLE IF NOT EXISTS entity_schema_fields (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    schema_id       UUID NOT NULL REFERENCES entity_schemas(id) ON DELETE CASCADE,
    name            VARCHAR(255) NOT NULL,
    display_name    VARCHAR(255),
    field_type      entity_field_type NOT NULL,
    required        BOOLEAN NOT NULL DEFAULT FALSE,
    description     TEXT,

    -- JSONB constraints store validation rules per field type:
    --
    -- string:  { "min_length": 1, "max_length": 500, "pattern": "^[a-z]" }
    -- integer: { "minimum": 0, "maximum": 100 }
    -- number:  { "minimum": 0.0, "maximum": 999.99 }
    -- boolean: { }  (no additional constraints)
    -- json:    { "schema": { "type": "object", "properties": {...} } }
    -- enum:    { "values": ["active", "inactive"] }
    -- map:     { "key_type": "string", "value_type": "string" }
    -- array:   { "item_type": "string", "max_items": 10 }
    -- date:    { "min_date": "2020-01-01", "max_date": "2030-12-31" }
    -- uuid:    { }  (format is implicit)
    -- email:   { }  (format is implicit)
    -- url:     { "max_length": 2048 }
    constraints     JSONB NOT NULL DEFAULT '{}',

    -- Default value for the field when creating entities (null = no default)
    default_value   JSONB,

    -- Ordering of fields within the schema
    ordinal         INTEGER NOT NULL DEFAULT 0,

    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- A field name must be unique within a schema
    CONSTRAINT uq_entity_schema_fields_schema_name UNIQUE (schema_id, name),

    -- Ordinal positions must be unique within a schema
    CONSTRAINT uq_entity_schema_fields_ordinal UNIQUE (schema_id, ordinal),

    -- Field name must be non-empty
    CONSTRAINT ck_entity_schema_fields_name_not_empty
        CHECK (length(trim(name)) > 0)
);

-- Indexes for query performance
CREATE INDEX IF NOT EXISTS idx_entity_schema_fields_schema_id
    ON entity_schema_fields(schema_id);
CREATE INDEX IF NOT EXISTS idx_entity_schema_fields_field_type
    ON entity_schema_fields(field_type);
CREATE INDEX IF NOT EXISTS idx_entity_schema_fields_required
    ON entity_schema_fields(schema_id, required);
CREATE INDEX IF NOT EXISTS idx_entity_schema_fields_ordinal
    ON entity_schema_fields(schema_id, ordinal);

-- ============================================================================
-- Table: entity_schema_versions
-- Immutable version history for schema definitions. Every time a schema
-- is created or updated, a full snapshot of its fields is captured here
-- for audit trail, rollback support, and event sourcing.
--
-- Gherkin mapping (SCENARIO 1):
--   "schema is assigned a unique schema ID and version number" →
--     entity_schema_versions.schema_id + entity_schema_versions.version
-- ============================================================================
CREATE TABLE IF NOT EXISTS entity_schema_versions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    schema_id       UUID NOT NULL REFERENCES entity_schemas(id) ON DELETE CASCADE,
    version         INTEGER NOT NULL,

    -- Full snapshot of the schema + fields at this version as JSONB
    -- This enables rollback: restore from an older version's snapshot
    schema_snapshot JSONB NOT NULL,

    -- Diff from previous version (null for v1)
    changelog       JSONB,

    -- Who created this version
    created_by      UUID,  -- FK to users table

    -- When this version was created
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Each schema can have only one version entry per version number
    CONSTRAINT uq_entity_schema_versions_schema_version UNIQUE (schema_id, version)
);

-- Indexes for query performance
CREATE INDEX IF NOT EXISTS idx_entity_schema_versions_schema_id
    ON entity_schema_versions(schema_id);
CREATE INDEX IF NOT EXISTS idx_entity_schema_versions_schema_version
    ON entity_schema_versions(schema_id, version DESC);
CREATE INDEX IF NOT EXISTS idx_entity_schema_versions_created_at
    ON entity_schema_versions(created_at DESC);

-- ============================================================================
-- Table: schema_validation_failures
-- Logs schema validation failures for the SchemaValidationFailed domain event.
--
-- Gherkin mapping (SCENARIO 2):
--   "request is rejected with a 400 Bad Request error" →
--     A row is inserted here with the failure details
--   "error message identifies the unsupported type" →
--     schema_validation_failures.error_message contains the unsupported type
-- ============================================================================
CREATE TABLE IF NOT EXISTS schema_validation_failures (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- The raw schema definition that was submitted (as received)
    submitted_schema JSONB NOT NULL,

    -- Validation error details
    failure_reason  VARCHAR(64) NOT NULL,  -- e.g., 'unsupported_field_type', 'invalid_pattern', 'invalid_constraint'
    failure_detail  TEXT NOT NULL,          -- Human-readable description identifying the issue

    -- Structured error metadata for programmatic handling
    -- Examples:
    --   { "field": "timeout_ms", "type": "float64", "valid_types": ["string", "int", "bool", "json"] }
    --   { "field": "name", "pattern": "[invalid", "error": "invalid regex: missing closing bracket" }
    error_metadata  JSONB NOT NULL DEFAULT '{}',

    -- Who submitted the invalid schema
    submitted_by    VARCHAR(255),  -- User/principal who made the request

    -- When the failure occurred
    failed_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Index for time-based queries
    CONSTRAINT ck_schema_validation_failures_reason_not_empty
        CHECK (length(trim(failure_reason)) > 0),
    CONSTRAINT ck_schema_validation_failures_detail_not_empty
        CHECK (length(trim(failure_detail)) > 0)
);

-- Indexes for query performance
CREATE INDEX IF NOT EXISTS idx_schema_validation_failures_failed_at
    ON schema_validation_failures(failed_at DESC);
CREATE INDEX IF NOT EXISTS idx_schema_validation_failures_reason
    ON schema_validation_failures(failure_reason);
CREATE INDEX IF NOT EXISTS idx_schema_validation_failures_submitted_by
    ON schema_validation_failures(submitted_by);

-- ============================================================================
-- Table: event_outbox
-- Transactional outbox (per ADR-002) for publishing domain events atomically
-- with the business data write.
--
-- Events published by this bounded context:
--   schema.SchemaDefined           — Event type: 'entity.SchemaDefined'
--   schema.SchemaValidationFailed  — Event type: 'entity.SchemaValidationFailed'
--   entity.EntityCreated           — Event type: 'entity.EntityCreated'
--   entity.EntityUpdated           — Event type: 'entity.EntityUpdated'
--   entity.EntityDeleted           — Event type: 'entity.EntityDeleted'
-- ============================================================================
CREATE TABLE IF NOT EXISTS event_outbox (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id        UUID NOT NULL,          -- UUID v7 for event deduplication
    event_type      VARCHAR(255) NOT NULL,  -- CloudEvents type: 'entity.SchemaDefined'
    source          VARCHAR(255) NOT NULL DEFAULT 'entity-management',
    subject         VARCHAR(255),           -- e.g., 'schema/{schemaId}', 'entity/{entityId}'
    data            JSONB NOT NULL,         -- Event payload (CloudEvents data)
    processed       BOOLEAN NOT NULL DEFAULT FALSE,
    retry_count     INTEGER NOT NULL DEFAULT 0,
    last_error      TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Idempotency: prevent duplicate event processing
    CONSTRAINT uq_event_outbox_event_id UNIQUE (event_id)
);

-- Index for efficient outbox relay: fetch oldest unprocessed events first
CREATE INDEX IF NOT EXISTS idx_event_outbox_unprocessed
    ON event_outbox(created_at ASC)
    WHERE processed = FALSE;

CREATE INDEX IF NOT EXISTS idx_event_outbox_event_type
    ON event_outbox(event_type);

CREATE INDEX IF NOT EXISTS idx_event_outbox_event_id
    ON event_outbox(event_id);

CREATE INDEX IF NOT EXISTS idx_event_outbox_subject
    ON event_outbox(subject);

CREATE INDEX IF NOT EXISTS idx_event_outbox_created_at
    ON event_outbox(created_at DESC);

-- ============================================================================
-- Function: log_schema_validation_failure()
-- Logs a schema validation failure and enqueues a SchemaValidationFailed event.
-- Called by the application layer when validation fails.
--
-- Usage:
--   PERFORM log_schema_validation_failure(
--     p_submitted_schema := '{"name": "Test", "fields": [{"name": "x", "type": "unsupported"}]}'::jsonb,
--     p_failure_reason := 'unsupported_field_type',
--     p_failure_detail := 'Field "x" has unsupported type "unsupported". Valid types: string, int, bool, json',
--     p_error_metadata := '{"field": "x", "type": "unsupported", "valid_types": ["string", "int", "bool", "json"]}'::jsonb,
--     p_submitted_by := 'u0000000-0000-4000-8000-000000000001'
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION log_schema_validation_failure(
    p_submitted_schema JSONB,
    p_failure_reason VARCHAR(64),
    p_failure_detail TEXT,
    p_error_metadata JSONB DEFAULT '{}',
    p_submitted_by VARCHAR(255) DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_failure_id UUID;
    v_event_id UUID;
BEGIN
    -- Insert the validation failure record
    INSERT INTO schema_validation_failures (
        id,
        submitted_schema,
        failure_reason,
        failure_detail,
        error_metadata,
        submitted_by,
        failed_at
    ) VALUES (
        gen_random_uuid(),
        p_submitted_schema,
        p_failure_reason,
        p_failure_detail,
        p_error_metadata,
        p_submitted_by,
        NOW()
    )
    RETURNING id INTO v_failure_id;

    -- Enqueue SchemaValidationFailed event to event_outbox
    v_event_id := gen_random_uuid();
    INSERT INTO event_outbox (
        id,
        event_id,
        event_type,
        source,
        subject,
        data,
        processed,
        retry_count,
        last_error,
        created_at
    ) VALUES (
        gen_random_uuid(),
        v_event_id,
        'entity.SchemaValidationFailed',
        'entity-management',
        'validation/failure/' || v_failure_id,
        jsonb_build_object(
            'failureId', v_failure_id,
            'submittedSchema', p_submitted_schema,
            'failureReason', p_failure_reason,
            'failureDetail', p_failure_detail,
            'errorMetadata', p_error_metadata,
            'submittedBy', p_submitted_by,
            'failedAt', NOW()
        ),
        FALSE,  -- Not yet processed by the outbox relay
        0,
        NULL,
        NOW()
    );

    RETURN v_failure_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- Function: enqueue_schema_defined_event()
-- Enqueues a SchemaDefined event for a newly created schema.
-- Called by the application layer after successfully persisting a schema.
--
-- Usage:
--   PERFORM enqueue_schema_defined_event(
--     p_schema_id := 'e0000001-...',
--     p_schema_name := 'Infrastructure Component',
--     p_slug := 'infrastructure-component',
--     p_version := 1,
--     p_created_by := 'u0000000-...'
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION enqueue_schema_defined_event(
    p_schema_id UUID,
    p_schema_name VARCHAR(255),
    p_slug VARCHAR(255),
    p_version INTEGER,
    p_created_by UUID DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_event_id UUID;
    v_outbox_id UUID;
BEGIN
    v_event_id := gen_random_uuid();

    INSERT INTO event_outbox (
        id,
        event_id,
        event_type,
        source,
        subject,
        data,
        processed,
        retry_count,
        last_error,
        created_at
    ) VALUES (
        gen_random_uuid(),
        v_event_id,
        'entity.SchemaDefined',
        'entity-management',
        'schema/' || p_schema_id,
        jsonb_build_object(
            'schemaId', p_schema_id,
            'schemaName', p_schema_name,
            'slug', p_slug,
            'version', p_version,
            'fields', (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'name', f.name,
                        'type', f.field_type,
                        'required', f.required,
                        'constraints', f.constraints
                    ) ORDER BY f.ordinal
                )
                FROM entity_schema_fields f
                WHERE f.schema_id = p_schema_id
            ),
            'createdBy', p_created_by,
            'createdAt', NOW()
        ),
        FALSE,  -- Not yet processed by the outbox relay
        0,
        NULL,
        NOW()
    )
    RETURNING id INTO v_outbox_id;

    RETURN v_outbox_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- Function: get_schema_with_fields()
-- Retrieves a complete schema definition including all its fields
-- in ordinal order. Returns the schema + fields as a JSONB object.
--
-- Usage:
--   SELECT get_schema_with_fields('e0000001-...');
--   SELECT get_schema_with_fields('e0000001-...', 2);
-- ============================================================================
CREATE OR REPLACE FUNCTION get_schema_with_fields(
    p_schema_id UUID,
    p_version INTEGER DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_result JSONB;
BEGIN
    SELECT jsonb_build_object(
        'schema_id', s.id,
        'name', s.name,
        'slug', s.slug,
        'version', COALESCE(p_version, s.version),
        'description', s.description,
        'status', s.status,
        'fields', COALESCE((
            SELECT jsonb_agg(
                jsonb_build_object(
                    'name', f.name,
                    'display_name', f.display_name,
                    'type', f.field_type,
                    'required', f.required,
                    'description', f.description,
                    'constraints', f.constraints,
                    'default_value', f.default_value,
                    'ordinal', f.ordinal
                ) ORDER BY f.ordinal
            )
            FROM entity_schema_fields f
            WHERE f.schema_id = s.id
        ), '[]'::jsonb),
        'created_by', s.created_by,
        'created_at', s.created_at,
        'updated_at', s.updated_at
    )
    INTO v_result
    FROM entity_schemas s
    WHERE s.id = p_schema_id;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- Function: validate_field_constraints()
-- Validates that the constraints JSONB conforms to the expected structure
-- for the given field type. Returns TRUE if valid, FALSE if invalid.
--
-- This is a database-level validation helper used by the application layer.
--
-- Usage:
--   SELECT validate_field_constraints('integer', '{"minimum": 0, "maximum": 100}');
--   → TRUE
--   SELECT validate_field_constraints('integer', '{"values": ["a"]}');
--   → FALSE (integer fields don't support 'values' constraint)
-- ============================================================================
CREATE OR REPLACE FUNCTION validate_field_constraints(
    p_field_type entity_field_type,
    p_constraints JSONB
)
RETURNS BOOLEAN AS $$
DECLARE
    v_valid_keys TEXT[];
    v_keys TEXT[];
    v_key TEXT;
BEGIN
    -- Define valid constraint keys per field type
    v_valid_keys := CASE p_field_type
        WHEN 'string'  THEN ARRAY['min_length', 'max_length', 'pattern']
        WHEN 'integer' THEN ARRAY['minimum', 'maximum']
        WHEN 'number'  THEN ARRAY['minimum', 'maximum']
        WHEN 'boolean' THEN ARRAY[]::TEXT[]
        WHEN 'json'    THEN ARRAY['schema']
        WHEN 'enum'    THEN ARRAY['values']
        WHEN 'map'     THEN ARRAY['key_type', 'value_type']
        WHEN 'array'   THEN ARRAY['item_type', 'max_items']
        WHEN 'date'    THEN ARRAY['min_date', 'max_date']
        WHEN 'datetime' THEN ARRAY['min_date', 'max_date']
        WHEN 'uuid'    THEN ARRAY[]::TEXT[]
        WHEN 'email'   THEN ARRAY[]::TEXT[]
        WHEN 'url'     THEN ARRAY['max_length']
    END;

    -- If no constraints provided, it's valid
    IF p_constraints IS NULL OR p_constraints = '{}'::jsonb THEN
        RETURN TRUE;
    END IF;

    -- Extract top-level keys from the constraints
    SELECT array_agg(k)
    INTO v_keys
    FROM jsonb_object_keys(p_constraints) AS k;

    -- Check that all keys are valid for this field type
    IF v_keys IS NOT NULL THEN
        FOREACH v_key IN ARRAY v_keys
        LOOP
            IF NOT (v_key = ANY(v_valid_keys)) THEN
                RETURN FALSE;
            END IF;
        END LOOP;
    END IF;

    -- Additional type-specific validation
    CASE p_field_type
        WHEN 'integer' THEN
            -- minimum and maximum must be integers
            IF p_constraints ? 'minimum' AND NOT (p_constraints->>'minimum') ~ '^-?[0-9]+$' THEN
                RETURN FALSE;
            END IF;
            IF p_constraints ? 'maximum' AND NOT (p_constraints->>'maximum') ~ '^-?[0-9]+$' THEN
                RETURN FALSE;
            END IF;

        WHEN 'string' THEN
            -- min_length and max_length must be non-negative integers
            IF p_constraints ? 'min_length' AND NOT (p_constraints->>'min_length') ~ '^[0-9]+$' THEN
                RETURN FALSE;
            END IF;
            IF p_constraints ? 'max_length' AND NOT (p_constraints->>'max_length') ~ '^[0-9]+$' THEN
                RETURN FALSE;
            END IF;
            -- min_length must be <= max_length if both are specified
            IF p_constraints ? 'min_length' AND p_constraints ? 'max_length' THEN
                IF (p_constraints->>'min_length')::INT > (p_constraints->>'max_length')::INT THEN
                    RETURN FALSE;
                END IF;
            END IF;
            -- pattern must be valid regex
            IF p_constraints ? 'pattern' THEN
                BEGIN
                    PERFORM (p_constraints->>'pattern')::TEXT ~ '.*';
                EXCEPTION WHEN OTHERS THEN
                    RETURN FALSE;
                END;
            END IF;

        WHEN 'enum' THEN
            -- 'values' must be a non-empty array
            IF NOT (p_constraints ? 'values' AND jsonb_typeof(p_constraints->'values') = 'array') THEN
                RETURN FALSE;
            END IF;
            IF jsonb_array_length(p_constraints->'values') = 0 THEN
                RETURN FALSE;
            END IF;

        WHEN 'array' THEN
            -- 'max_items' must be a positive integer if specified
            IF p_constraints ? 'max_items' AND NOT (p_constraints->>'max_items') ~ '^[1-9][0-9]*$' THEN
                RETURN FALSE;
            END IF;

        ELSE
            -- For other types, no additional validation beyond key checking
            NULL;
    END CASE;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ============================================================================
-- Function: create_schema_snapshot()
-- Captures a full snapshot of a schema and its fields for the version history.
-- Called automatically when a schema is created.
--
-- Returns the UUID of the inserted version record.
-- ============================================================================
CREATE OR REPLACE FUNCTION create_schema_snapshot(
    p_schema_id UUID,
    p_version INTEGER,
    p_changelog JSONB DEFAULT NULL,
    p_created_by UUID DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_version_id UUID;
    v_snapshot JSONB;
BEGIN
    -- Build the full schema snapshot
    v_snapshot := get_schema_with_fields(p_schema_id, p_version);

    -- Insert into version history
    INSERT INTO entity_schema_versions (
        id,
        schema_id,
        version,
        schema_snapshot,
        changelog,
        created_by,
        created_at
    ) VALUES (
        gen_random_uuid(),
        p_schema_id,
        p_version,
        v_snapshot,
        p_changelog,
        p_created_by,
        NOW()
    )
    RETURNING id INTO v_version_id;

    RETURN v_version_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- Function: get_schema_diff()
-- Compares two versions of a schema and returns the differences.
-- Useful for the Gherkin "version number" scenario — shows what changed.
--
-- Usage:
--   SELECT * FROM get_schema_diff('e0000001-...', 1, 2);
-- ============================================================================
CREATE OR REPLACE FUNCTION get_schema_diff(
    p_schema_id UUID,
    p_version_old INTEGER,
    p_version_new INTEGER
)
RETURNS JSONB AS $$
DECLARE
    v_old_snapshot JSONB;
    v_new_snapshot JSONB;
    v_diff JSONB;
BEGIN
    -- Retrieve the two version snapshots
    SELECT schema_snapshot INTO v_old_snapshot
    FROM entity_schema_versions
    WHERE schema_id = p_schema_id AND version = p_version_old;

    SELECT schema_snapshot INTO v_new_snapshot
    FROM entity_schema_versions
    WHERE schema_id = p_schema_id AND version = p_version_new;

    -- Return null if either version doesn't exist
    IF v_old_snapshot IS NULL OR v_new_snapshot IS NULL THEN
        RETURN NULL;
    END IF;

    -- Build a diff object
    SELECT jsonb_build_object(
        'old_version', p_version_old,
        'new_version', p_version_new,
        'fields_added', (
            SELECT jsonb_agg(nf.name)
            FROM jsonb_to_recordset(v_new_snapshot->'fields') AS nf(name text)
            WHERE nf.name NOT IN (
                SELECT of.name
                FROM jsonb_to_recordset(v_old_snapshot->'fields') AS of(name text)
            )
        ),
        'fields_removed', (
            SELECT jsonb_agg(of.name)
            FROM jsonb_to_recordset(v_old_snapshot->'fields') AS of(name text)
            WHERE of.name NOT IN (
                SELECT nf.name
                FROM jsonb_to_recordset(v_new_snapshot->'fields') AS nf(name text)
            )
        ),
        'fields_modified', (
            SELECT jsonb_agg(
                jsonb_build_object(
                    'name', nf.name,
                    'old_type', of.type,
                    'new_type', nf.type,
                    'old_required', of.required,
                    'new_required', nf.required
                )
            )
            FROM jsonb_to_recordset(v_old_snapshot->'fields') AS of(name text, type text, required bool)
            JOIN jsonb_to_recordset(v_new_snapshot->'fields') AS nf(name text, type text, required bool)
                ON of.name = nf.name
            WHERE of.type IS DISTINCT FROM nf.type
               OR of.required IS DISTINCT FROM nf.required
        )
    ) INTO v_diff;

    RETURN v_diff;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- Down
-- ============================================================================
-- DROP FUNCTION IF EXISTS get_schema_diff(UUID, INTEGER, INTEGER);
-- DROP FUNCTION IF EXISTS create_schema_snapshot(UUID, INTEGER, JSONB, UUID);
-- DROP FUNCTION IF EXISTS validate_field_constraints(entity_field_type, JSONB);
-- DROP FUNCTION IF EXISTS get_schema_with_fields(UUID, INTEGER);
-- DROP FUNCTION IF EXISTS enqueue_schema_defined_event(UUID, VARCHAR, VARCHAR, INTEGER, UUID);
-- DROP FUNCTION IF EXISTS log_schema_validation_failure(JSONB, VARCHAR, TEXT, JSONB, VARCHAR);
-- DROP FUNCTION IF EXISTS is_supported_field_type(TEXT);
-- DROP TRIGGER IF EXISTS update_entity_schemas_modtime ON entity_schemas;
-- DROP TABLE IF EXISTS event_outbox;
-- DROP TABLE IF EXISTS schema_validation_failures;
-- DROP TABLE IF EXISTS entity_schema_versions;
-- DROP TABLE IF EXISTS entity_schema_fields;
-- DROP TABLE IF EXISTS entity_schemas;
-- DROP TYPE IF EXISTS entity_field_type;
-- DROP TYPE IF EXISTS entity_schema_status;
