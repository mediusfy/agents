-- Seed: ENT-01 Example Schema Definitions for Entity Management
-- Story: ENT-01: Define Entity Schema with typed fields and validation rules
--
-- This seed provides:
--   1. Realistic schema definitions matching the Gherkin scenarios
--   2. A validation failure example (SchemaValidationFailed)
--   3. Schema version history snapshots (immutable audit trail)
--   4. SchemaDefined events in the transactional outbox
--   5. A SchemaValidationFailed event in the transactional outbox
--
-- Gherkin SCENARIO 1: "Successfully define a new entity schema"
--   → Infrastructure Component schema with string, int, bool, json fields
--   → Service Endpoint schema with multiple field types
--
-- Gherkin SCENARIO 2: "Reject schema with unsupported field type"
--   → Schema validation failure logged for an unsupported 'float64' type

-- ============================================================================
-- Seed 1: Infrastructure Component Schema (v1)
-- Demonstrates Gherkin SCENARIO 1: field types (string, int, bool, json)
-- and validation rules (required, min, max, pattern).
-- ============================================================================
WITH schema_insert AS (
    INSERT INTO entity_schemas (id, name, slug, version, description, status, created_by, created_at)
    VALUES (
        'e0000001-0000-4000-8000-000000000001',
        'Infrastructure Component',
        'infrastructure-component',
        1,
        'Blueprint for infrastructure components managed across cloud regions. ' ||
        'Demonstrates all Gherkin-specified field types: string, int, bool, json.',
        'active',
        'u0000000-0000-4000-8000-000000000001',  -- admin user
        NOW() - INTERVAL '1 day'
    )
    RETURNING id
)
INSERT INTO entity_schema_fields (schema_id, name, display_name, field_type, required, description, constraints, default_value, ordinal)
SELECT
    id, 'name', 'Component Name', 'string', TRUE,
    'The unique name identifying this infrastructure component.',
    '{"min_length": 1, "max_length": 255, "pattern": "^[a-zA-Z0-9_-]+$"}',
    NULL, 1
FROM schema_insert
UNION ALL
SELECT
    id, 'region', 'Cloud Region', 'string', TRUE,
    'The cloud provider region where the component is deployed.',
    '{"min_length": 2, "max_length": 20, "pattern": "^[a-z]{2}-[a-z]+-[0-9]+$"}',
    '"us-east-1"', 2
FROM schema_insert
UNION ALL
SELECT
    id, 'status', 'Component Status', 'string', TRUE,
    'The lifecycle status of the component.',
    '{"min_length": 1, "max_length": 20, "pattern": "^(active|inactive|deleted|provisioning)$"}',
    '"active"', 3
FROM schema_insert
UNION ALL
SELECT
    id, 'replicas', 'Replica Count', 'integer', TRUE,
    'Number of replicas for this component (Gherkin: int type).',
    '{"minimum": 1, "maximum": 100}',
    '1', 4
FROM schema_insert
UNION ALL
SELECT
    id, 'auto_scaling_enabled', 'Auto Scaling Enabled', 'boolean', FALSE,
    'Whether auto-scaling is enabled for this component (Gherkin: bool type).',
    '{}',
    'false', 5
FROM schema_insert
UNION ALL
SELECT
    id, 'configuration', 'Configuration', 'json', FALSE,
    'Arbitrary JSON configuration for advanced settings (Gherkin: json type).',
    '{}',
    NULL, 6
FROM schema_insert
UNION ALL
SELECT
    id, 'metadata', 'Component Metadata', 'json', FALSE,
    'Arbitrary key-value metadata for annotations and tags.',
    '{}',
    NULL, 7
FROM schema_insert;

-- ============================================================================
-- Seed 2: Service Endpoint Schema (v1)
-- A more complex schema demonstrating additional field types and constraints
-- beyond the Gherkin-specified core types.
-- ============================================================================
WITH schema_insert AS (
    INSERT INTO entity_schemas (id, name, slug, version, description, status, created_by, created_at)
    VALUES (
        'e0000001-0000-4000-8000-000000000002',
        'Service Endpoint',
        'service-endpoint',
        1,
        'Blueprint for API service endpoints with health check and routing configuration.',
        'active',
        'u0000000-0000-4000-8000-000000000001',
        NOW() - INTERVAL '12 hours'
    )
    RETURNING id
)
INSERT INTO entity_schema_fields (schema_id, name, display_name, field_type, required, description, constraints, default_value, ordinal)
SELECT
    id, 'name', 'Endpoint Name', 'string', TRUE,
    'The logical name of the service endpoint.',
    '{"min_length": 2, "max_length": 128, "pattern": "^[a-z][a-z0-9-]*$"}',
    NULL, 1
FROM schema_insert
UNION ALL
SELECT
    id, 'url', 'Endpoint URL', 'string', TRUE,
    'The full URL of the service endpoint.',
    '{"min_length": 5, "max_length": 2048, "pattern": "^https?://"}',
    NULL, 2
FROM schema_insert
UNION ALL
SELECT
    id, 'timeout_ms', 'Timeout (ms)', 'integer', TRUE,
    'Request timeout in milliseconds.',
    '{"minimum": 100, "maximum": 30000}',
    '5000', 3
FROM schema_insert
UNION ALL
SELECT
    id, 'enabled', 'Enabled', 'boolean', FALSE,
    'Whether this endpoint is currently active and accepting traffic.',
    '{}',
    'true', 4
FROM schema_insert
UNION ALL
SELECT
    id, 'retry_config', 'Retry Configuration', 'json', FALSE,
    'JSON retry configuration (backoff, max_retries, timeout).',
    '{}',
    NULL, 5
FROM schema_insert;

-- ============================================================================
-- Seed 3: Deprecated Schema Example
-- Shows schema deprecation lifecycle
-- ============================================================================
INSERT INTO entity_schemas (id, name, slug, version, description, status, created_by, created_at, updated_at)
VALUES (
    'e0000001-0000-4000-8000-000000000003',
    'Legacy Config V1',
    'legacy-config-v1',
    1,
    'Deprecated configuration schema — use "Infrastructure Component" instead.',
    'deprecated',
    'u0000000-0000-4000-8000-000000000001',
    NOW() - INTERVAL '30 days',
    NOW() - INTERVAL '1 day'
);

-- ============================================================================
-- Seed 4: Infrastructure Component Schema (v2)
-- Demonstrates schema versioning — adds owner and cost_center fields.
-- The name+version uniqueness constraint allows multiple versions.
-- ============================================================================
WITH schema_insert AS (
    INSERT INTO entity_schemas (id, name, slug, version, description, status, created_by, created_at)
    VALUES (
        'e0000001-0000-4000-8000-000000000011',  -- Different UUID from v1
        'Infrastructure Component',
        'infrastructure-component',
        2,
        'Blueprint for infrastructure components — v2 adds owner and cost_center fields.',
        'active',
        'u0000000-0000-4000-8000-000000000001',
        NOW()
    )
    RETURNING id
)
INSERT INTO entity_schema_fields (schema_id, name, display_name, field_type, required, description, constraints, default_value, ordinal)
SELECT
    id, 'name', 'Component Name', 'string', TRUE,
    'The unique name identifying this infrastructure component.',
    '{"min_length": 1, "max_length": 255, "pattern": "^[a-zA-Z0-9_-]+$"}',
    NULL, 1
FROM schema_insert
UNION ALL
SELECT
    id, 'region', 'Cloud Region', 'string', TRUE,
    'The cloud provider region where the component is deployed.',
    '{"min_length": 2, "max_length": 20, "pattern": "^[a-z]{2}-[a-z]+-[0-9]+$"}',
    '"us-east-1"', 2
FROM schema_insert
UNION ALL
SELECT
    id, 'status', 'Component Status', 'string', TRUE,
    'The lifecycle status of the component.',
    '{"min_length": 1, "max_length": 20, "pattern": "^(active|inactive|deleted|provisioning)$"}',
    '"active"', 3
FROM schema_insert
UNION ALL
SELECT
    id, 'replicas', 'Replica Count', 'integer', TRUE,
    'Number of replicas for this component.',
    '{"minimum": 1, "maximum": 100}',
    '1', 4
FROM schema_insert
UNION ALL
SELECT
    id, 'auto_scaling_enabled', 'Auto Scaling Enabled', 'boolean', FALSE,
    'Whether auto-scaling is enabled.',
    '{}',
    'false', 5
FROM schema_insert
UNION ALL
SELECT
    id, 'configuration', 'Configuration', 'json', FALSE,
    'Arbitrary JSON configuration for advanced settings.',
    '{}',
    NULL, 6
FROM schema_insert
UNION ALL
SELECT
    id, 'metadata', 'Component Metadata', 'json', FALSE,
    'Arbitrary key-value metadata.',
    '{}',
    NULL, 7
FROM schema_insert
UNION ALL
SELECT
    id, 'owner', 'Owner', 'string', TRUE,
    'The team or individual responsible for this component.',
    '{"min_length": 1, "max_length": 128}',
    NULL, 8
FROM schema_insert
UNION ALL
SELECT
    id, 'cost_center', 'Cost Center', 'string', FALSE,
    'The cost center code for FinOps chargeback.',
    '{"min_length": 7, "max_length": 7, "pattern": "^CC-[0-9]{4}$"}',
    NULL, 9
FROM schema_insert;

-- ============================================================================
-- Seed 5: Version History — Infrastructure Component v1 snapshot
-- (Immutable audit trail for schema definitions)
-- ============================================================================
INSERT INTO entity_schema_versions (id, schema_id, version, schema_snapshot, changelog, created_by, created_at)
SELECT
    gen_random_uuid(),
    s.id,
    1,
    jsonb_build_object(
        'schema_id', s.id,
        'name', s.name,
        'slug', s.slug,
        'version', 1,
        'description', s.description,
        'status', s.status,
        'fields', (
            SELECT jsonb_agg(
                jsonb_build_object(
                    'name', f.name,
                    'display_name', f.display_name,
                    'field_type', f.field_type,
                    'required', f.required,
                    'constraints', f.constraints,
                    'default_value', f.default_value,
                    'ordinal', f.ordinal
                ) ORDER BY f.ordinal
            )
            FROM entity_schema_fields f
            WHERE f.schema_id = s.id
        ),
        'created_by', s.created_by,
        'created_at', s.created_at
    ),
    NULL,  -- v1 has no changelog
    s.created_by,
    s.created_at
FROM entity_schemas s
WHERE s.name = 'Infrastructure Component' AND s.version = 1;

-- ============================================================================
-- Seed 6: Version History — Infrastructure Component v2 snapshot
-- (with changelog showing added fields)
-- ============================================================================
INSERT INTO entity_schema_versions (id, schema_id, version, schema_snapshot, changelog, created_by, created_at)
SELECT
    gen_random_uuid(),
    s.id,
    2,
    jsonb_build_object(
        'schema_id', s.id,
        'name', s.name,
        'slug', s.slug,
        'version', 2,
        'description', s.description,
        'status', s.status,
        'fields', (
            SELECT jsonb_agg(
                jsonb_build_object(
                    'name', f.name,
                    'display_name', f.display_name,
                    'field_type', f.field_type,
                    'required', f.required,
                    'constraints', f.constraints,
                    'default_value', f.default_value,
                    'ordinal', f.ordinal
                ) ORDER BY f.ordinal
            )
            FROM entity_schema_fields f
            WHERE f.schema_id = s.id
        ),
        'created_by', s.created_by,
        'created_at', s.created_at
    ),
    jsonb_build_object(
        'added_fields', jsonb_build_array('owner', 'cost_center'),
        'summary', 'Added owner (required) and cost_center (optional) fields with pattern validation.'
    ),
    s.created_by,
    s.created_at
FROM entity_schemas s
WHERE s.name = 'Infrastructure Component' AND s.version = 2;

-- ============================================================================
-- Seed 7: Version History — Service Endpoint v1 snapshot
-- ============================================================================
INSERT INTO entity_schema_versions (id, schema_id, version, schema_snapshot, changelog, created_by, created_at)
SELECT
    gen_random_uuid(),
    s.id,
    1,
    jsonb_build_object(
        'schema_id', s.id,
        'name', s.name,
        'slug', s.slug,
        'version', 1,
        'description', s.description,
        'status', s.status,
        'fields', (
            SELECT jsonb_agg(
                jsonb_build_object(
                    'name', f.name,
                    'display_name', f.display_name,
                    'field_type', f.field_type,
                    'required', f.required,
                    'constraints', f.constraints,
                    'default_value', f.default_value,
                    'ordinal', f.ordinal
                ) ORDER BY f.ordinal
            )
            FROM entity_schema_fields f
            WHERE f.schema_id = s.id
        ),
        'created_by', s.created_by,
        'created_at', s.created_at
    ),
    NULL,
    s.created_by,
    s.created_at
FROM entity_schemas s
WHERE s.name = 'Service Endpoint' AND s.version = 1;

-- ============================================================================
-- Seed 8: Schema Validation Failure Example (Gherkin SCENARIO 2)
-- Demonstrates what happens when a platform engineer submits a schema
-- with an unsupported field type — the failure is logged and a
-- SchemaValidationFailed event is emitted.
--
-- Gherkin:
--   "Given a platform engineer submits a schema with an unsupported field type"
--   "When the schema is validated"
--   "Then the request is rejected with a 400 Bad Request error"
--   "And the error message identifies the unsupported type"
-- ============================================================================
DO $$
DECLARE
    v_failure_id UUID;
    v_submitted_schema JSONB;
BEGIN
    -- Simulate a schema submission with an unsupported field type ('float64')
    -- This represents what happens in the application layer when validation fails
    v_submitted_schema := jsonb_build_object(
        'name', 'Invalid Schema',
        'slug', 'invalid-schema',
        'description', 'This schema contains an unsupported field type',
        'fields', jsonb_build_array(
            jsonb_build_object(
                'name', 'timeout_seconds',
                'type', 'float64',  -- Unsupported type! Valid: string, int, bool, json
                'required', TRUE,
                'description', 'Timeout in seconds'
            )
        )
    );

    -- Log the validation failure using the helper function
    v_failure_id := log_schema_validation_failure(
        p_submitted_schema := v_submitted_schema,
        p_failure_reason := 'unsupported_field_type',
        p_failure_detail := 'Field "timeout_seconds" has unsupported type "float64". ' ||
                            'Valid types for entity schemas are: string, int, bool, json, ' ||
                            'number, enum, map, array, date, datetime, uuid, email, url.',
        p_error_metadata := jsonb_build_object(
            'field', 'timeout_seconds',
            'submitted_type', 'float64',
            'valid_types', jsonb_build_array('string', 'int', 'bool', 'json', 'number', 'enum', 'map', 'array', 'date', 'datetime', 'uuid', 'email', 'url'),
            'hint', 'Use "number" for floating-point values or "integer" for whole numbers.'
        ),
        p_submitted_by := 'u0000000-0000-4000-8000-000000000001'
    );

    RAISE NOTICE 'Schema validation failure logged: % (reason: unsupported_field_type)', v_failure_id;
END $$;

-- ============================================================================
-- Seed 9: Event Outbox — SchemaDefined events for valid schemas
-- These represent the events published when schemas are created.
-- In production, these are written atomically via the transactional outbox
-- pattern using the enqueue_schema_defined_event() function.
-- ============================================================================

-- SchemaDefined: Infrastructure Component v1
INSERT INTO event_outbox (id, event_id, event_type, source, subject, data, processed, created_at)
SELECT
    gen_random_uuid(),
    gen_random_uuid(),
    'entity.SchemaDefined',
    'entity-management',
    'schema/' || s.id,
    jsonb_build_object(
        'schemaId', s.id,
        'name', s.name,
        'slug', s.slug,
        'version', s.version,
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
            WHERE f.schema_id = s.id
        ),
        'createdBy', s.created_by,
        'createdAt', s.created_at
    ),
    TRUE,  -- Marked as processed for seed data
    s.created_at
FROM entity_schemas s
WHERE s.name = 'Infrastructure Component' AND s.version = 1;

-- SchemaDefined: Infrastructure Component v2
INSERT INTO event_outbox (id, event_id, event_type, source, subject, data, processed, created_at)
SELECT
    gen_random_uuid(),
    gen_random_uuid(),
    'entity.SchemaDefined',
    'entity-management',
    'schema/' || s.id,
    jsonb_build_object(
        'schemaId', s.id,
        'name', s.name,
        'slug', s.slug,
        'version', s.version,
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
            WHERE f.schema_id = s.id
        ),
        'createdBy', s.created_by,
        'createdAt', s.created_at
    ),
    TRUE,
    s.created_at
FROM entity_schemas s
WHERE s.name = 'Infrastructure Component' AND s.version = 2;

-- SchemaDefined: Service Endpoint v1
INSERT INTO event_outbox (id, event_id, event_type, source, subject, data, processed, created_at)
SELECT
    gen_random_uuid(),
    gen_random_uuid(),
    'entity.SchemaDefined',
    'entity-management',
    'schema/' || s.id,
    jsonb_build_object(
        'schemaId', s.id,
        'name', s.name,
        'slug', s.slug,
        'version', s.version,
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
            WHERE f.schema_id = s.id
        ),
        'createdBy', s.created_by,
        'createdAt', s.created_at
    ),
    TRUE,
    s.created_at
FROM entity_schemas s
WHERE s.name = 'Service Endpoint' AND s.version = 1;

-- ============================================================================
-- Seed 10: Verify the seed data via helper functions
-- ============================================================================

-- Demonstrate get_schema_with_fields() for Infrastructure Component v1
DO $$
DECLARE
    v_schema_id UUID;
    v_result JSONB;
BEGIN
    SELECT id INTO v_schema_id
    FROM entity_schemas
    WHERE name = 'Infrastructure Component' AND version = 1;

    v_result := get_schema_with_fields(v_schema_id);
    RAISE NOTICE 'Infrastructure Component v1 schema: %', v_result;
END $$;

-- Demonstrate get_schema_diff() between v1 and v2
DO $$
DECLARE
    v_schema_id UUID;
    v_diff JSONB;
BEGIN
    SELECT id INTO v_schema_id
    FROM entity_schemas
    WHERE name = 'Infrastructure Component' AND version = 1;

    v_diff := get_schema_diff(
        (SELECT id FROM entity_schemas WHERE name = 'Infrastructure Component' AND version = 1),
        1, 2
    );
    RAISE NOTICE 'Diff between v1 and v2: %', v_diff;
END $$;

-- Demonstrate validate_field_constraints()
DO $$
BEGIN
    IF validate_field_constraints('integer', '{"minimum": 0, "maximum": 100}') THEN
        RAISE NOTICE 'Valid integer constraints: OK';
    END IF;

    IF NOT validate_field_constraints('integer', '{"values": ["a", "b"]}') THEN
        RAISE NOTICE 'Invalid integer constraints (values not valid for integer): correctly rejected';
    END IF;

    IF validate_field_constraints('string', '{"min_length": 1, "max_length": 255, "pattern": "^[a-z]+$"}') THEN
        RAISE NOTICE 'Valid string constraints: OK';
    END IF;

    IF validate_field_constraints('boolean', '{}') THEN
        RAISE NOTICE 'Valid boolean constraints (empty): OK';
    END IF;

    IF validate_field_constraints('json', '{"schema": {"type": "object"}}') THEN
        RAISE NOTICE 'Valid json constraints: OK';
    END IF;

    IF NOT validate_field_constraints('string', '{"minimum": 0}') THEN
        RAISE NOTICE 'Invalid string constraints (minimum not valid for string): correctly rejected';
    END IF;

    -- Test pattern validation
    IF NOT validate_field_constraints('string', '{"pattern": "[invalid"}') THEN
        RAISE NOTICE 'Invalid regex pattern: correctly rejected';
    END IF;
END $$;

-- Demonstrate is_supported_field_type()
DO $$
BEGIN
    IF is_supported_field_type('string') THEN
        RAISE NOTICE 'string: supported — OK';
    END IF;
    IF is_supported_field_type('integer') THEN
        RAISE NOTICE 'integer (Gherkin: int): supported — OK';
    END IF;
    IF is_supported_field_type('boolean') THEN
        RAISE NOTICE 'boolean (Gherkin: bool): supported — OK';
    END IF;
    IF is_supported_field_type('json') THEN
        RAISE NOTICE 'json (Gherkin: json): supported — OK';
    END IF;
    IF NOT is_supported_field_type('float64') THEN
        RAISE NOTICE 'float64 (unsupported): correctly rejected — OK';
    END IF;
    IF NOT is_supported_field_type('unknown_type') THEN
        RAISE NOTICE 'unknown_type (unsupported): correctly rejected — OK';
    END IF;
END $$;

-- ============================================================================
-- Summary: Verify seed data counts
-- ============================================================================
DO $$
DECLARE
    v_schema_count INTEGER;
    v_field_count INTEGER;
    v_version_count INTEGER;
    v_failure_count INTEGER;
    v_event_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_schema_count FROM entity_schemas;
    SELECT COUNT(*) INTO v_field_count FROM entity_schema_fields;
    SELECT COUNT(*) INTO v_version_count FROM entity_schema_versions;
    SELECT COUNT(*) INTO v_failure_count FROM schema_validation_failures;
    SELECT COUNT(*) INTO v_event_count FROM event_outbox WHERE event_type LIKE 'entity.Schema%';

    RAISE NOTICE '=== ENTITY-01 Seed Summary ===';
    RAISE NOTICE 'Schemas:             %', v_schema_count;
    RAISE NOTICE 'Fields:              %', v_field_count;
    RAISE NOTICE 'Version snapshots:   %', v_version_count;
    RAISE NOTICE 'Validation failures: %', v_failure_count;
    RAISE NOTICE 'Schema events:       %', v_event_count;
    RAISE NOTICE 'Status: ✅ ENTITY-01 seed data loaded successfully';
END $$;
