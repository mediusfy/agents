-- Seed: 003_entity_data.sql
-- Description: ENT-02: Create Entity — Seed data for the ServiceComponent
-- entity schema definition and sample entity instances.
--
-- This seed:
--   1. Defines the "ServiceComponent" entity schema (used in Gherkin scenarios)
--   2. Creates sample entity instances matching the Gherkin payload
--   3. Seeds the event_outbox with EntityCreated events for traceability
--   4. Seeds idempotency records for event deduplication assurance

-- ============================================================================
-- Seed 1: ServiceComponent Schema (v1)
-- The schema referenced by the Gherkin "Given a defined entity schema for
-- 'ServiceComponent'" — a blueprint for cloud service components.
--
-- Fields:
--   name     (string, required) — Component name (e.g., "api-gateway")
--   region   (string, required) — Cloud region from allowed enum
--   status   (enum, required)   — Component status from allowed values
-- ============================================================================
WITH schema_insert AS (
    INSERT INTO entity_schemas (id, name, slug, version, description, status, created_by, created_at)
    VALUES (
        'f0000001-0000-4000-8000-000000000001',  -- ServiceComponent schema UUID
        'ServiceComponent',
        'service-component',
        1,
        'Blueprint for deployable service components managed across cloud regions. ' ||
        'Supports multi-cloud deployments with data residency constraints. ' ||
        'Each component has a name, deployment region, and lifecycle status.',
        'active',
        'u0000000-0000-4000-8000-000000000001',  -- admin user
        NOW() - INTERVAL '2 days'
    )
    RETURNING id
)
INSERT INTO entity_schema_fields (schema_id, name, display_name, field_type, required, description, constraints, default_value, ordinal)
SELECT
    id, 'name', 'Component Name', 'string', TRUE,
    'The unique name identifying this service component (e.g., "api-gateway", "user-service").',
    '{"min_length": 1, "max_length": 255, "pattern": "^[a-zA-Z0-9_-]+$"}',
    NULL, 1
FROM schema_insert
UNION ALL
SELECT
    id, 'region', 'Cloud Region', 'string', TRUE,
    'The cloud provider region where the service component is deployed.',
    '{"enum": ["us-east-1", "eu-west-1", "us-west-2"]}',  -- NOTE: ap-southeast-1 NOT allowed (per Gherkin)
    '"us-east-1"', 2
FROM schema_insert
UNION ALL
SELECT
    id, 'status', 'Component Status', 'enum', TRUE,
    'The lifecycle status of the service component.',
    '{"values": ["active", "inactive", "deleted", "provisioning"]}',
    '"active"', 3
FROM schema_insert
UNION ALL
SELECT
    id, 'owner', 'Owner', 'string', FALSE,
    'The team or individual responsible for this service component.',
    '{"min_length": 1, "max_length": 128}',
    NULL, 4
FROM schema_insert
UNION ALL
SELECT
    id, 'version', 'Component Version', 'string', FALSE,
    'The deployed version of the service component (semver).',
    '{"pattern": "^[0-9]+\\.[0-9]+\\.[0-9]+$"}',
    NULL, 5
FROM schema_insert;

-- ============================================================================
-- Seed 2: ServiceComponent Schema (v1) — Version History Snapshot
-- Captures the immutable audit trail entry for the schema definition.
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
WHERE s.name = 'ServiceComponent' AND s.version = 1;

-- ============================================================================
-- Seed 3: Entity Instances (matching Gherkin scenario)
-- Creates sample entities conforming to the ServiceComponent schema.
-- The "api-gateway" entity matches the Gherkin payload exactly.
-- ============================================================================
WITH created_entities AS (
    INSERT INTO entities (id, schema_id, schema_version, name, type, region, status, attributes, created_at)
    VALUES
        -- Matches Gherkin payload: { "name": "api-gateway", "region": "us-east-1", "status": "active" }
        (
            'a1000001-0000-4000-8000-000000000001',
            (SELECT id FROM entity_schemas WHERE slug = 'service-component'),
            1,
            'api-gateway',
            'ServiceComponent',
            'us-east-1',
            'active',
            '{"owner": "platform-team", "version": "2.1.3"}'::jsonb,
            NOW() - INTERVAL '1 hour'
        ),
        -- Additional sample entity: user-service in eu-west-1
        (
            'a1000001-0000-4000-8000-000000000002',
            (SELECT id FROM entity_schemas WHERE slug = 'service-component'),
            1,
            'user-service',
            'ServiceComponent',
            'eu-west-1',
            'active',
            '{"owner": "identity-team", "version": "1.0.0"}'::jsonb,
            NOW() - INTERVAL '30 minutes'
        ),
        -- Sample entity in provisioning status
        (
            'a1000001-0000-4000-8000-000000000003',
            (SELECT id FROM entity_schemas WHERE slug = 'service-component'),
            1,
            'analytics-pipeline',
            'ServiceComponent',
            'us-west-2',
            'provisioning',
            '{"owner": "data-team"}'::jsonb,
            NOW() - INTERVAL '5 minutes'
        )
    RETURNING id, name, region, status, created_at, schema_id
)
-- ============================================================================
-- Seed 4: Event Outbox — EntityCreated events
-- These represent the events published when entities are created.
-- In production, these are written atomically via the transactional outbox
-- pattern within the same database transaction as the entity insert.
-- ============================================================================
INSERT INTO event_outbox (id, event_id, event_type, source, subject, data, processed, created_at)
SELECT
    gen_random_uuid(),
    gen_random_uuid(),
    'entity.EntityCreated',
    'entity-management',
    'entity/' || ce.id,
    jsonb_build_object(
        'entityId', ce.id,
        'entityName', ce.name,
        'entityType', 'ServiceComponent',
        'region', ce.region,
        'status', ce.status,
        'createdAt', ce.created_at,
        'schemaVersion', 1
    ),
    TRUE,  -- Marked as processed for seed data
    ce.created_at
FROM created_entities ce;

-- ============================================================================
-- Seed 5: Entity SchemaDefined event for ServiceComponent
-- Published when the ServiceComponent schema was defined.
-- ============================================================================
INSERT INTO event_outbox (id, event_id, event_type, source, subject, data, processed, created_at)
SELECT
    gen_random_uuid(),
    gen_random_uuid(),
    'entity.EntitySchemaDefined',
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
WHERE s.name = 'ServiceComponent' AND s.version = 1;

-- ============================================================================
-- Seed 6: Idempotency Records (for event deduplication)
-- Demonstrates the idempotency tracking for processed events.
-- In production, these are written atomically alongside entity creation
-- to ensure exactly-once event delivery semantics.
-- ============================================================================
INSERT INTO entity_idempotency (event_id, entity_id, event_type, processed_at)
SELECT
    eo.event_id,
    (eo.data->>'entityId')::uuid,
    eo.event_type,
    eo.created_at
FROM event_outbox eo
WHERE eo.event_type = 'entity.EntityCreated'
  AND eo.processed = TRUE
ON CONFLICT (event_id, entity_id) DO NOTHING;
