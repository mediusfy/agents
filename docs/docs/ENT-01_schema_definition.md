# ENT-01: Define Entity Schema

> **Story:** ENT-01 — Define Entity Schema  
> **Status:** ✅ Implemented (Migration + Seed)  
> **Domain:** Entity Management (Core Domain)  
> **Event:** `entity.EntitySchemaDefined`  
> **Consumers:** AuditLog, SchemaRegistry  

---

## 1. Overview

Platform engineers (admin role) can define dynamic entity schemas/blueprints that specify the structure, types, constraints, and default values for entity attributes. These schemas are the foundation for all entity CRUD operations within the Entity Management bounded context.

### Gherkin Acceptance Criteria

```gherkin
Scenario: Successfully define a new entity schema
  Given a platform engineer with admin privileges
  When I define an entity schema with attributes:
    | attribute | type   | required | constraints                  |
    | name      | string | yes      |                              |
    | region    | string | yes      | enum: us-east-1, eu-west-1   |
    | status    | enum   | yes      | active|inactive              |
    | metadata  | map    | no       |                              |
  Then the schema is persisted in the Entity Management context
  And an entity.EntitySchemaDefined event is published with the schema definition
  And the schema is available for CRUD operations immediately

Scenario: Missing required field
  Given no name attribute is provided in the schema
  When I attempt to define the schema
  Then a 400 Bad Request is returned
  And no event is published
```

---

## 2. Database Schema

### Entity-Relationship Diagram (Textual)

```
┌─────────────────────────────────────────────────────────────────┐
│                      entity_schemas                             │
├─────────────────────────────────────────────────────────────────┤
│  id            UUID PRIMARY KEY                                 │
│  name          VARCHAR(255) NOT NULL                            │
│  slug          VARCHAR(255) NOT NULL                            │
│  version       INTEGER NOT NULL DEFAULT 1                       │
│  description   TEXT                                             │
│  status        entity_schema_status (active|inactive|deprecated)│
│  created_by    UUID (FK → users)                                │
│  created_at    TIMESTAMPTZ                                      │
│  updated_at    TIMESTAMPTZ                                      │
├─────────────────────────────────────────────────────────────────┤
│  UNIQUE(name, version)                                          │
│  UNIQUE(slug) WHERE status != 'deprecated'                      │
└────────────────────────────────┬────────────────────────────────┘
                                 │ 1
                                 │
                                 │ *
                    ┌────────────▼─────────────────────────────┐
                    │           entity_schema_fields            │
                    ├──────────────────────────────────────────┤
                    │  id            UUID PRIMARY KEY           │
                    │  schema_id     UUID FK → entity_schemas   │
                    │  name          VARCHAR(255) NOT NULL      │
                    │  display_name  VARCHAR(255)               │
                    │  field_type    entity_field_type (enum)   │
                    │  required      BOOLEAN DEFAULT FALSE      │
                    │  description   TEXT                       │
                    │  constraints   JSONB                      │
                    │  default_value JSONB                      │
                    │  ordinal       INTEGER NOT NULL           │
                    │  created_at    TIMESTAMPTZ                │
                    ├──────────────────────────────────────────┤
                    │  UNIQUE(schema_id, name)                  │
                    └──────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                   entity_schema_versions                        │
├─────────────────────────────────────────────────────────────────┤
│  id              UUID PRIMARY KEY                               │
│  schema_id       UUID FK → entity_schemas                       │
│  version         INTEGER NOT NULL                               │
│  schema_snapshot JSONB (full snapshot of schema + fields)       │
│  changelog       JSONB (diff from previous version)             │
│  created_by      UUID (FK → users)                              │
│  created_at      TIMESTAMPTZ                                    │
├─────────────────────────────────────────────────────────────────┤
│  UNIQUE(schema_id, version)                                     │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                       event_outbox                              │
├─────────────────────────────────────────────────────────────────┤
│  id            UUID PRIMARY KEY                                 │
│  event_id      UUID NOT NULL (v7, for deduplication)            │
│  event_type    VARCHAR(255) NOT NULL                            │
│  source        VARCHAR(255) DEFAULT 'entity-management'         │
│  subject       VARCHAR(255)                                     │
│  data          JSONB NOT NULL (CloudEvents-compliant payload)   │
│  processed     BOOLEAN DEFAULT FALSE                            │
│  retry_count   INTEGER DEFAULT 0                                │
│  last_error    TEXT                                              │
│  created_at    TIMESTAMPTZ                                      │
└─────────────────────────────────────────────────────────────────┘
```

### Supported Field Types

| Type | Constraints Supported | Example |
|------|----------------------|---------|
| `string` | `min_length`, `max_length`, `pattern` | `{"min_length": 1, "max_length": 255}` |
| `number` | `minimum`, `maximum`, `multiple_of` | `{"minimum": 0, "maximum": 100.0}` |
| `integer` | `minimum`, `maximum`, `multiple_of` | `{"minimum": 1, "maximum": 100}` |
| `boolean` | — | `{}` |
| `enum` | `values` (array of allowed values) | `{"values": ["active", "inactive"]}` |
| `map` | `key_type`, `value_type` | `{"key_type": "string", "value_type": "string"}` |
| `array` | `item_type`, `min_items`, `max_items` | `{"item_type": "string", "max_items": 10}` |
| `date` | `min_date`, `max_date` | `{}` |
| `datetime` | `min_datetime`, `max_datetime` | `{}` |
| `uuid` | — | `{}` |
| `email` | — | `{}` |
| `url` | `max_length` | `{"max_length": 2048}` |

---

## 3. Event Contract

### `entity.EntitySchemaDefined`

**Owner:** EntityManagement  
**Consumers:** AuditLog, SchemaRegistry  
**Format:** CloudEvents (via transactional outbox)

```json
{
  "event_id": "018f3e6a-9b5c-7a00-8000-000000000001",
  "event_type": "entity.EntitySchemaDefined",
  "source": "entity-management",
  "subject": "schema/e0000001-0000-4000-8000-000000000001",
  "data": {
    "schemaId": "e0000001-0000-4000-8000-000000000001",
    "name": "Infrastructure Component",
    "slug": "infrastructure-component",
    "version": 1,
    "fields": [
      {
        "name": "name",
        "type": "string",
        "required": true,
        "constraints": {
          "min_length": 1,
          "max_length": 255,
          "pattern": "^[a-zA-Z0-9_-]+$"
        }
      },
      {
        "name": "region",
        "type": "string",
        "required": true,
        "constraints": {
          "enum": ["us-east-1", "eu-west-1"]
        }
      },
      {
        "name": "status",
        "type": "enum",
        "required": true,
        "constraints": {
          "values": ["active", "inactive"]
        }
      },
      {
        "name": "metadata",
        "type": "map",
        "required": false,
        "constraints": {
          "key_type": "string",
          "value_type": "string"
        }
      }
    ],
    "createdBy": "u0000000-0000-4000-8000-000000000001",
    "createdAt": "2026-06-03T12:00:00Z"
  }
}
```

---

## 4. Caching Strategy (Redis)

### Cache Key Structure

| Key Pattern | Type | TTL | Description |
|-------------|------|-----|-------------|
| `entity:schema:<schema_id>` | String (JSON) | 1 hour | Full schema definition with fields |
| `entity:schema:slug:<slug>` | String (JSON) | 1 hour | Schema lookup by slug |
| `entity:schema:active` | Set | 1 hour | Set of all active schema IDs |
| `entity:schema:version:<schema_id>` | String (number) | No expiry | Current version for cache invalidation |

### Invalidation Strategy

- **Write-through**: On schema creation/update, invalidate the corresponding cache keys
- **Version-based**: The `version` field acts as an implicit cache buster
- **Background invalidation**: Use Redis keyspace notifications (`notify-keyspace-events Ex`) for cross-instance invalidation

---

## 5. Index Strategy

| Table | Index | Type | Rationale |
|-------|-------|------|-----------|
| `entity_schemas` | `(name, version)` | UNIQUE B-tree | Enforce schema version uniqueness |
| `entity_schemas` | `(slug)` WHERE status != 'deprecated' | UNIQUE B-tree | Unique slug lookup for active schemas |
| `entity_schemas` | `(status)` | B-tree | Filter active/inactive/deprecated schemas |
| `entity_schemas` | `(created_by)` | B-tree | Find schemas created by a user |
| `entity_schemas` | `(created_at DESC)` | B-tree | Default ordering for listing |
| `entity_schema_fields` | `(schema_id)` | B-tree | Fast field lookup by schema |
| `entity_schema_fields` | `(field_type)` | B-tree | Filter fields by type |
| `entity_schema_fields` | `(schema_id, required)` | Composite B-tree | Find required fields for validation |
| `entity_schema_fields` | `(schema_id, name)` | UNIQUE B-tree | Prevent duplicate field names |
| `entity_schema_versions` | `(schema_id)` | B-tree | Version history for a schema |
| `entity_schema_versions` | `(schema_id, version)` | UNIQUE B-tree | Unique per-version snapshot |
| `entity_schema_versions` | `(created_at DESC)` | B-tree | Chronological version history |
| `event_outbox` | `(created_at)` WHERE processed = FALSE | Partial B-tree | Efficient outbox polling |
| `event_outbox` | `(event_type)` | B-tree | Filter events by type |
| `event_outbox` | `(event_id)` | B-tree | Deduplication lookups |

---

## 6. Validation Rules

### Schema-Level Validation

1. **Name must be present** (Gherkin: "Missing required field" → 400 Bad Request)
2. **Name must be unique** (case-insensitive) among active schemas
3. **Slug must be unique** among active/non-deprecated schemas
4. **At least one field** must be defined
5. **Version** auto-increments on schema updates

### Field-Level Validation

1. **Field name** must be unique within a schema (case-sensitive)
2. **Field type** must be one of the supported `entity_field_type` enum values
3. **Constraints** must match the field type (e.g., `values` is only valid for `enum` type)
4. **Display name** defaults to field name if not provided
5. **Ordinal** ordering must be non-negative; gaps are allowed

---

## 7. Error Codes

| HTTP Status | Error Code | Description |
|-------------|------------|-------------|
| 400 | `ERR_MISSING_SCHEMA_NAME` | Schema name is required |
| 400 | `ERR_DUPLICATE_SCHEMA_NAME` | Schema with this name already exists |
| 400 | `ERR_DUPLICATE_SLUG` | Schema with this slug already exists |
| 400 | `ERR_MISSING_FIELD_NAME` | Each field must have a name |
| 400 | `ERR_DUPLICATE_FIELD_NAME` | Duplicate field name within schema |
| 400 | `ERR_INVALID_FIELD_TYPE` | Unsupported field type |
| 400 | `ERR_INVALID_CONSTRAINTS` | Constraints don't match field type |
| 400 | `ERR_NO_FIELDS` | Schema must have at least one field |
| 404 | `ERR_SCHEMA_NOT_FOUND` | Schema ID or slug not found |
| 409 | `ERR_SCHEMA_CONFLICT` | Schema version conflict on update |

---

## 8. Migration Files

| File | Description |
|------|-------------|
| `docs/migrations/002_create_entity_schemas.sql` | DDL for entity_schemas, entity_schema_fields, entity_schema_versions, event_outbox tables |
| `docs/seeds/002_entity_schema_data.sql` | Example schema definitions, version history, and outbox events |
| `docs/config/redis-entity-schema.conf` | Redis caching configuration for schema lookups |

---

## 9. Related ADRs

- **ADR-002**: Eventing Strategy — Transactional outbox pattern (Firestore-style, but implemented in PostgreSQL)
- The event_outbox table implements the outbox pattern described in ADR-002 using PostgreSQL instead of Firestore
