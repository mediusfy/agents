# ENTITY-01: Define Entity Schema with Typed Fields and Validation Rules

## Story
> As a platform engineer with admin privileges, I want to define entity schemas with typed fields and validation rules so that entities can be created consistently across multi-cloud regions.

## Gherkin Scenarios

### Scenario 1: Successfully define a new entity schema
```
Given a platform engineer submits a schema definition with field types
  (string, int, bool, json) and validation rules (required, min, max, pattern)
When the schema is persisted
Then the schema is assigned a unique schema ID and version number
And the schema is available for entity creation
```

### Scenario 2: Reject schema with unsupported field type
```
Given a platform engineer submits a schema with an unsupported field type
When the schema is validated
Then the request is rejected with a 400 Bad Request error
And the error message identifies the unsupported type
```

## Domain Events

| Event | Type | Description |
|-------|------|-------------|
| `schema.SchemaDefined` | `entity.SchemaDefined` | Fires after a valid schema definition is submitted, validated, and successfully persisted to the schema store. The schema is now available for entity creation. |
| `schema.SchemaValidationFailed` | `entity.SchemaValidationFailed` | Fires when the submitted schema definition fails validation (e.g., unsupported field type, invalid regex pattern, or out-of-range min/max values). The schema is not persisted. |

## Database Schema

### Migration: `docs/migrations/002_create_entity_schemas.sql`

| Table | Purpose |
|-------|---------|
| `entity_schemas` | Core schema definitions — each schema gets a UUID (`id`) and an auto-incrementing `version` |
| `entity_schema_fields` | Typed fields per schema version; supports `string`, `integer`, `boolean`, `json`, `number`, `enum`, `map`, `array`, `date`, `datetime`, `uuid`, `email`, `url` |
| `entity_schema_versions` | Immutable version history — full JSONB snapshot per version for audit trail and rollback |
| `schema_validation_failures` | Logs validation failures (Gherkin Scenario 2) |
| `event_outbox` | Transactional outbox for domain event publishing (ADR-002) |

### Gherkin-to-Table Mapping

| Gherkin Concept | Database Column |
|----------------|----------------|
| "unique schema ID" | `entity_schemas.id` (UUID) |
| "version number" | `entity_schemas.version` (INTEGER) |
| "field types (string, int, bool, json)" | `entity_schema_fields.field_type` (ENUM) |
| "validation rules (required)" | `entity_schema_fields.required` (BOOLEAN) |
| "validation rules (min)" | `entity_schema_fields.constraints->'minimum'` / `constraints->'min_length'` |
| "validation rules (max)" | `entity_schema_fields.constraints->'maximum'` / `constraints->'max_length'` |
| "validation rules (pattern)" | `entity_schema_fields.constraints->'pattern'` |
| "400 Bad Request error" | `schema_validation_failures` row inserted + `SchemaValidationFailed` event emitted |

### Helper Functions

| Function | Purpose |
|----------|---------|
| `is_supported_field_type(TEXT)` | Checks if a field type is a member of the `entity_field_type` enum |
| `validate_field_constraints(entity_field_type, JSONB)` | Validates constraint JSON against expected structure per field type |
| `log_schema_validation_failure(...)` | Logs a validation failure and enqueues `SchemaValidationFailed` event |
| `enqueue_schema_defined_event(...)` | Enqueues `SchemaDefined` event with full schema+fields payload |
| `get_schema_with_fields(UUID, INTEGER)` | Returns complete schema definition with all fields as JSONB |
| `create_schema_snapshot(...)` | Captures a version snapshot into `entity_schema_versions` |
| `get_schema_diff(UUID, INTEGER, INTEGER)` | Computes differences between two schema versions |

## Redis Caching

Configuration: `docs/config/redis-entity-schema.conf`

- **maxmemory**: 128mb
- **Eviction policy**: allkeys-lru
- **Persistence**: RDB snapshots (source of truth is PostgreSQL)
- **Key pattern**: `entity:schema:<schema_id>`, `entity:schema:slug:<slug>`, `entity:schema:active`, `entity:schema:version:<schema_id>`

## Seed Data

File: `docs/seeds/002_entity_schema_data.sql`

- **Infrastructure Component v1**: Demonstrates all Gherkin field types (string, int, bool, json)
- **Infrastructure Component v2**: Versioned schema with added fields and changelog
- **Service Endpoint v1**: Complex schema with multiple field types
- **Legacy Config V1**: Deprecated schema lifecycle example
- **Schema Validation Failure**: Example of Scenario 2 (unsupported type `float64`)
- **SchemaDefined Events**: Transactional outbox entries for each schema
- **Verification Queries**: Demonstrates all helper functions working correctly

## Domain Types (Go)

File: `entity-management/internal/domain/types.go`

The domain types align with the database schema:

```go
type AttributeType string

const (
    AttributeTypeString AttributeType = "string"
    AttributeTypeInt    AttributeType = "int"
    AttributeTypeBool   AttributeType = "bool"
    AttributeTypeJSON   AttributeType = "json"  // Gherkin-specified type
    AttributeTypeEnum   AttributeType = "enum"
    AttributeTypeMap    AttributeType = "map"
)

type Constraint struct {
    Min     *int    `json:"min,omitempty"`
    Max     *int    `json:"max,omitempty"`
    Pattern string  `json:"pattern,omitempty"`
}

type AttributeDefinition struct {
    Name       string        `json:"name"`
    Type       AttributeType `json:"type"`
    Required   bool          `json:"required"`
    Constraint *Constraint   `json:"constraint,omitempty"`
}

type EntitySchema struct {
    ID         string                `json:"id"`
    Name       string                `json:"name"`
    Version    int                   `json:"version"`
    Attributes []AttributeDefinition `json:"attributes"`
    CreatedAt  time.Time             `json:"created_at"`
    UpdatedAt  time.Time             `json:"updated_at"`
}
```

## Validation Rules

### Supported Constraints Per Field Type

| Field Type | Valid Constraints | Example |
|------------|------------------|---------|
| `string` | `min_length`, `max_length`, `pattern` | `{"min_length": 1, "max_length": 255, "pattern": "^[a-z]+$"}` |
| `integer` | `minimum`, `maximum` | `{"minimum": 1, "maximum": 100}` |
| `boolean` | (none) | `{}` |
| `json` | `schema` | `{"schema": {"type": "object", "properties": {...}}}` |
| `number` | `minimum`, `maximum` | `{"minimum": 0.0, "maximum": 999.99}` |
| `enum` | `values` | `{"values": ["active", "inactive"]}` |
| `map` | `key_type`, `value_type` | `{"key_type": "string", "value_type": "string"}` |
| `array` | `item_type`, `max_items` | `{"item_type": "string", "max_items": 10}` |
| `date` | `min_date`, `max_date` | `{"min_date": "2020-01-01", "max_date": "2030-12-31"}` |
| `datetime` | `min_date`, `max_date` | (same as date) |
| `uuid` | (none) | `{}` |
| `email` | (none) | `{}` |
| `url` | `max_length` | `{"max_length": 2048}` |

## Event Payloads

### SchemaDefined Event (`entity.SchemaDefined`)
```json
{
  "schemaId": "e0000001-0000-4000-8000-000000000001",
  "schemaName": "Infrastructure Component",
  "slug": "infrastructure-component",
  "version": 1,
  "fields": [
    {"name": "name", "type": "string", "required": true, "constraints": {"min_length": 1, "max_length": 255}},
    {"name": "replicas", "type": "integer", "required": true, "constraints": {"minimum": 1, "maximum": 100}},
    {"name": "auto_scaling_enabled", "type": "boolean", "required": false, "constraints": {}},
    {"name": "configuration", "type": "json", "required": false, "constraints": {}}
  ],
  "createdBy": "u0000000-0000-4000-8000-000000000001",
  "createdAt": "2026-06-03T12:00:00Z"
}
```

### SchemaValidationFailed Event (`entity.SchemaValidationFailed`)
```json
{
  "failureId": "<uuid>",
  "submittedSchema": {
    "name": "Invalid Schema",
    "fields": [{"name": "timeout_seconds", "type": "float64", "required": true}]
  },
  "failureReason": "unsupported_field_type",
  "failureDetail": "Field \"timeout_seconds\" has unsupported type \"float64\". Valid types for entity schemas are: string, int, bool, json, number, enum, map, array, date, datetime, uuid, email, url.",
  "errorMetadata": {
    "field": "timeout_seconds",
    "submitted_type": "float64",
    "valid_types": ["string", "int", "bool", "json", "number", "enum", "map", "array", "date", "datetime", "uuid", "email", "url"]
  },
  "submittedBy": "u0000000-0000-4000-8000-000000000001",
  "failedAt": "2026-06-03T12:00:00Z"
}
```
