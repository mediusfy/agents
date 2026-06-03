

# ENTITYMGMT-01: Schema Definition with Typed Attributes

## Story

**Admin defines an entity schema with typed attributes.**

As an administrator of the Entity Management system, I want to define entity schemas with typed attributes so that conforming entity instances can be created with validated, type-safe fields.

## Gherkin Scenarios

### Scenario 1: Successfully define a Customer schema

```gherkin
Given the system is initialized with empty schema registry
When an admin defines an entity schema named "Customer"
  And includes attributes with all supported types:
    | name     | type   | required | constraint          |
    | email    | string | true     | pattern=^[^@]+@[^@]+$ |
    | age      | int    | false    | min=0 max=150       |
    | isActive | bool   | false    |                     |
    | status   | enum   | true     | enum=[active,inactive] |
    | metadata | map    | false    |                     |
    | config   | json   | false    |                     |
Then the schema is stored with a unique schema ID and version 1
  And an entitymanagement.schema.defined CloudEvent is written to the transactional outbox
```

### Scenario 2: Duplicate schema name

```gherkin
Given a schema named "Customer" already exists
When an admin attempts to define another schema with the same name
Then the operation fails with ErrSchemaAlreadyExists
  And no schema.defined event is emitted
```

## Domain Events

### entitymanagement.schema.defined

- **Owned by**: EntityManagement context
- **Triggered when**: A new entity schema is successfully defined with typed attributes
- **Payload**: `{event_id, schema_id, schema_name, version: 1, attributes: [{name, type, required, constraint}], occurred_at}`
- **Consumers**:
  - **ValidatorCache**: Compile schema rules for entity validation
  - **ResidencyContext**: Tag schema with data residency region
  - **Monitoring**: Schema creation audit trail

## Database Tables

### entity_schemas (Aggregate Root)

| Column       | Type               | Description                                    |
|-------------|--------------------|------------------------------------------------|
| id          | UUID (PK)          | Unique schema ID (auto-generated)              |
| name        | VARCHAR(255)       | Schema name (unique, active)                   |
| version     | INTEGER            | Version number (starts at 1)                   |
| status      | VARCHAR(32)        | Lifecycle: active, inactive, deprecated        |
| created_by  | VARCHAR(255)       | Who created the schema                         |
| created_at  | TIMESTAMPTZ        | Creation timestamp                             |
| updated_at  | TIMESTAMPTZ        | Last update timestamp (auto)                   |

**Constraints**:
- `uq_entity_schemas_name`: Unique schema name (SCENARIO 2 enforcement)
- `ck_entity_schemas_name_not_empty`: Name must be non-empty

### entity_schema_attributes (Normalized Attributes)

| Column      | Type                              | Description                          |
|------------|-----------------------------------|--------------------------------------|
| id         | UUID (PK)                         | Unique attribute ID                  |
| schema_id  | UUID (FK → entity_schemas)        | Parent schema                        |
| name       | VARCHAR(255)                      | Attribute name (e.g., "email")       |
| attr_type  | entity_management_attribute_type  | Type: string, int, bool, enum, map, json |
| required   | BOOLEAN                           | Whether attribute is required        |
| constraints| JSONB                             | Validation constraints (type-dependent) |
| ordinal    | INTEGER                           | Position within schema               |
| created_at | TIMESTAMPTZ                       | Creation timestamp                   |

**Supported Types**:

| Type   | Constraints JSONB Structure               |
|--------|-------------------------------------------|
| string | `{"pattern": "...", "min_length": N, "max_length": N}` |
| int    | `{"min": N, "max": N}`                    |
| bool   | `{}`                                      |
| enum   | `{"enum": ["val1", "val2"]}`              |
| map    | `{}`                                      |
| json   | `{}`                                      |

### outbox_events (Transactional Outbox)

| Column        | Type      | Description                                  |
|--------------|-----------|----------------------------------------------|
| id           | TEXT (PK) | Unique outbox event ID                       |
| event_id     | TEXT      | UUID v4 for event deduplication              |
| aggregate_id | TEXT      | ID of the aggregate that emitted the event   |
| aggregate_type| TEXT     | Type of aggregate (e.g., 'schema')           |
| event_type   | TEXT      | CloudEvents type (e.g., 'entitymanagement.schema.defined') |
| source       | TEXT      | CloudEvents source ('/entity-manager')       |
| subject      | TEXT      | CloudEvents subject (e.g., 'schema/<uuid>')  |
| payload      | JSONB     | Event payload                                |
| status       | TEXT      | 'pending', 'published', 'failed'             |
| retry_count  | INTEGER   | Number of delivery retries                   |
| last_error   | TEXT      | Last error message                           |
| created_at   | TIMESTAMPTZ | Creation timestamp                         |

## Key Functions

### `define_schema_with_attributes(name, attributes, created_by)`
Atomic operation that creates schema + attributes + outbox event in one transaction.
Returns `(schema_id, name, version, event_id, is_new)`.

### `enqueue_schema_defined_event(schema_id, schema_name, version, created_by)`
Inserts an `entitymanagement.schema.defined` event into the outbox table.

### `get_schema_with_attributes(schema_id)`
Retrieves a full schema with all attributes as a JSONB array.

### `find_schema_by_name(schema_name)`
Finds the latest active schema by name (returns NULL if not found).

### `schema_exists(schema_name)`
Boolean check for schema existence (used by SCENARIO 2).

## Migration Files

| File | Path |
|------|------|
| Up Migration | `entity-management/database/migrations/ENTITYMGMT-01_000_schema_definition.up.sql` |
| Down Migration | `entity-management/database/migrations/ENTITYMGMT-01_000_schema_definition.down.sql` |
| Seed Data | `entity-management/database/seeds/ENTITYMGMT-01_000_schema_definition_seed.sql` |
| Queries | `entity-management/database/queries/ENTITYMGMT-01_define_schema.sql` |
| Redis Config | `entity-management/config/redis/cache.conf` |

## Go Domain Model Alignment

The SQL schema maps directly to the Go domain types in `internal/domain/types.go`:

| Go Type | SQL Type |
|---------|----------|
| `domain.AttributeType` (`string`, `int`, `bool`, `enum`, `map`, `json`) | `entity_management_attribute_type` ENUM |
| `domain.AttributeDefinition{Name, Type, Required, Constraint}` | `entity_schema_attributes` row |
| `domain.Constraint{Enum, Min, Max, Pattern}` | `constraints` JSONB column |
| `domain.EntitySchema{ID, Name, Version, Attributes, CreatedAt, UpdatedAt}` | `entity_schemas` + JOIN `entity_schema_attributes` |
| `domain.ErrSchemaAlreadyExists` | `uq_entity_schemas_name` UNIQUE constraint |

## Redis Cache Strategy

The ValidatorCache consumer uses Redis to cache compiled schema validation rules:

- **Key**: `schema:rules:{schema_id}`
- **Value**: JSON compiled rules
- **TTL**: 1 hour (3600s)
- **Eviction**: allkeys-lru (256 MB max)

## Related Files

- `internal/domain/types.go` — Domain types and error sentinels
- `internal/domain/service.go` — SchemaService and DefineSchema logic
- `internal/ports/events.go` — CloudEvents envelope definitions
- `internal/adapters/postgres/postgres_repo.go` — PostgreSQL repository implementation
- `internal/application/service.go` — SchemaService use case orchestration
