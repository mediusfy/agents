-- Query: ENTITYMGMT-01_define_schema.sql
-- Story: ENTITYMGMT-01 — Admin defines an entity schema with typed attributes
-- Bounded Context: Entity Management
--
-- These queries support the application repository layer for schema operations.
-- They are used by entity-management/internal/adapters/postgres/ (SchemaRepository)
-- and the entity-management/internal/application/ (SchemaService).
--
-- ============================================================================
-- Query 1: Save a new entity schema (with attributes as JSONB array)
-- Used by: SchemaRepository.Save() in postgres_repo.go
--
-- The attributes are stored as a normalized table (entity_schema_attributes)
-- for queryability, but the application layer also reads/writes the attributes
-- as a JSONB array for convenience.
--
-- The Go domain.EntitySchema stores attributes as []domain.AttributeDefinition
-- which serializes to a JSON array. This query stores the schema row; attributes
-- are inserted separately into entity_schema_attributes.
-- ============================================================================

-- :name save-schema
-- :command :insert
-- :result :raw
INSERT INTO entity_schemas (id, name, version, status, created_by, created_at, updated_at)
VALUES ($1, $2, $3, 'active', $4, $5, $6)
ON CONFLICT (id) DO UPDATE SET
    version    = EXCLUDED.version,
    status     = 'active',
    updated_at = NOW();

-- ============================================================================
-- Query 2: Insert a single attribute into entity_schema_attributes
-- Used by: SchemaRepository.Save() to persist normalized attributes
-- ============================================================================

-- :name save-schema-attribute
-- :command :insert
-- :result :raw
INSERT INTO entity_schema_attributes (id, schema_id, name, attr_type, required, constraints, ordinal, created_at)
VALUES ($1, $2, $3, $4::entity_management_attribute_type, $5, $6::jsonb, $7, $8)
ON CONFLICT (schema_id, name) DO UPDATE SET
    attr_type   = EXCLUDED.attr_type,
    required    = EXCLUDED.required,
    constraints = EXCLUDED.constraints,
    ordinal     = EXCLUDED.ordinal;

-- ============================================================================
-- Query 3: Find schema by ID (with attributes)
-- Used by: SchemaRepository.FindByID()
-- ============================================================================

-- :name find-schema-by-id
-- :command :query
-- :result :one
SELECT
    s.id,
    s.name,
    s.version,
    s.status,
    s.created_by,
    COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'name',        a.name,
                'type',        a.attr_type,
                'required',    a.required,
                'constraint',  a.constraints
            ) ORDER BY a.ordinal
        ) FILTER (WHERE a.id IS NOT NULL),
        '[]'::jsonb
    ) AS attributes,
    s.created_at,
    s.updated_at
FROM entity_schemas s
LEFT JOIN entity_schema_attributes a ON a.schema_id = s.id
WHERE s.id = $1
GROUP BY s.id, s.name, s.version, s.status, s.created_by, s.created_at, s.updated_at;

-- ============================================================================
-- Query 4: Find schema by name (latest active version)
-- Used by: SchemaRepository.FindByName()
-- ============================================================================

-- :name find-schema-by-name
-- :command :query
-- :result :one
SELECT
    s.id,
    s.name,
    s.version,
    s.status,
    s.created_by,
    COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'name',        a.name,
                'type',        a.attr_type,
                'required',    a.required,
                'constraint',  a.constraints
            ) ORDER BY a.ordinal
        ) FILTER (WHERE a.id IS NOT NULL),
        '[]'::jsonb
    ) AS attributes,
    s.created_at,
    s.updated_at
FROM entity_schemas s
LEFT JOIN entity_schema_attributes a ON a.schema_id = s.id
WHERE s.name = $1 AND s.status = 'active'
GROUP BY s.id, s.name, s.version, s.status, s.created_by, s.created_at, s.updated_at
ORDER BY s.version DESC
LIMIT 1;

-- ============================================================================
-- Query 5: Find all schemas (latest active version of each name)
-- Used by: SchemaRepository.FindAll()
-- ============================================================================

-- :name find-all-schemas
-- :command :query
-- :result :many
SELECT
    s.id,
    s.name,
    s.version,
    s.status,
    s.created_by,
    COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'name',        a.name,
                'type',        a.attr_type,
                'required',    a.required,
                'constraint',  a.constraints
            ) ORDER BY a.ordinal
        ) FILTER (WHERE a.id IS NOT NULL),
        '[]'::jsonb
    ) AS attributes,
    s.created_at,
    s.updated_at,
    (SELECT COUNT(*) FROM entity_schema_attributes ea WHERE ea.schema_id = s.id) AS attribute_count
FROM entity_schemas s
LEFT JOIN entity_schema_attributes a ON a.schema_id = s.id
WHERE s.status = 'active'
GROUP BY s.id, s.name, s.version, s.status, s.created_by, s.created_at, s.updated_at
ORDER BY s.name;

-- ============================================================================
-- Query 6: Delete schema by ID (cascades to attributes and versions)
-- Used by: SchemaRepository.Delete()
-- ============================================================================

-- :name delete-schema-by-id
-- :command :execute
-- :result :affected
DELETE FROM entity_schemas WHERE id = $1;

-- ============================================================================
-- Query 7: Check if schema name exists
-- Used by: application layer for ErrSchemaAlreadyExists check (SCENARIO 2)
-- ============================================================================

-- :name check-schema-exists
-- :command :query
-- :result :one
SELECT EXISTS(
    SELECT 1 FROM entity_schemas WHERE name = $1 AND status = 'active'
) AS exists;

-- ============================================================================
-- Query 8: Enqueue entitymanagement.schema.defined event
-- Used by: SchemaRepository / application layer for transactional outbox
-- ============================================================================

-- :name enqueue-schema-defined-event
-- :command :insert
-- :result :raw
INSERT INTO outbox_events (
    id, event_id, aggregate_id, aggregate_type,
    event_type, source, subject, payload,
    status, retry_count, last_error, created_at
) VALUES (
    gen_random_uuid()::TEXT,
    $1::TEXT,         -- event_id
    $2::TEXT,         -- schema_id (aggregate_id)
    'schema',
    'entitymanagement.schema.defined',
    '/entity-manager',
    'schema/' || $2::TEXT,
    jsonb_build_object(
        'event_id',    $1::TEXT,
        'schema_id',   $2::TEXT,
        'schema_name', $3,
        'version',     $4,
        'attributes',  $5::jsonb,
        'created_by',  $6,
        'occurred_at', NOW()
    ),
    'pending',
    0,
    NULL,
    NOW()
);

-- ============================================================================
-- Query 9: Atomic schema definition with attributes and event
-- Wraps define_schema_with_attributes() for use by the application layer.
-- Returns (schema_id, schema_name, version, event_id, is_new).
-- If is_new = FALSE, the caller should return ErrSchemaAlreadyExists.
-- ============================================================================

-- :name define-schema-with-attributes
-- :command :query
-- :result :one
SELECT * FROM define_schema_with_attributes(
    p_name       := $1,
    p_attributes := $2::jsonb,
    p_created_by := $3
);
