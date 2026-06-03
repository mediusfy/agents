# ENT-02: Create Entity

> **Story:** ENT-02 — Create Entity  
> **Status:** ✅ Implemented (Migration + Seed)  
> **Domain:** Entity Management (Core Domain)  
> **Event:** `entity.EntityCreated`  
> **Consumers:** ServiceRegistry (via ACL), AuditLog, SearchIndex  
> **Depends on:** ENT-01 (entity_schemas table must exist)

---

## 1. Overview

Users can create a new entity instance conforming to a previously defined entity schema. The entity is validated against its schema's field definitions, persisted to the `entities` table, and an `entity.EntityCreated` event is published via the transactional outbox pattern.

### Gherkin Acceptance Criteria

```gherkin
Feature: Entity Creation
  Scenario: Successfully create an entity
    Given a defined entity schema for "ServiceComponent"
    And a valid payload: { "name": "api-gateway", "region": "us-east-1", "status": "active" }
    When I POST /api/v1/entities with the payload
    Then the entity is created with a unique UUID
    And the response is 201 Created
    And the response body contains the full entity with id, createdAt
    And an entity.EntityCreated event is emitted

  Scenario: Validation failure — missing required field
    Given a payload missing required field "name"
    When I POST /api/v1/entities
    Then the response is 400 Bad Request
    And the error body specifies the missing field
    And no entity.EntityCreated event is published

  Scenario: Validation failure — invalid enum value
    Given a payload with region "ap-southeast-1" (not in allowed enum)
    When I POST /api/v1/entities
    Then the response is 400 Bad Request
    And no event is published
```

---

## 2. Database Schema

### Entity-Relationship Diagram (Textual)

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           entity_schemas                                │
│                              (ENT-01)                                   │
│  PK: id                                                                 │
│  name, slug, version, status, description, created_by, timestamps       │
└──────────────────┬──────────────────────────────────────────────────────┘
                   │ 1
                   │
                   │ * (FK: schema_id)
    ┌──────────────▼──────────────────────────────────────────────────────┐
    │                              entities                                │
    ├──────────────────────────────────────────────────────────────────────┤
    │  PK: id              UUID      DEFAULT gen_random_uuid()            │
    │  schema_id           UUID      NOT NULL → entity_schemas(id)        │
    │  schema_version      INTEGER   NOT NULL DEFAULT 1                   │
    │  name                VARCHAR   NOT NULL (unique per schema)         │
    │  type                VARCHAR   NOT NULL (denormalized schema name)  │
    │  region              VARCHAR   NOT NULL                             │
    │  status              ENUM      NOT NULL DEFAULT 'active'            │
    │  data_residency_zone TEXT      GENERATED (computed from region)     │
    │  attributes          JSONB     NOT NULL DEFAULT '{}'                │
    │  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()             │
    │  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()             │
    ├──────────────────────────────────────────────────────────────────────┤
    │  UNIQUE(schema_id, name)                                            │
    │  CHECK(name NOT EMPTY)                                              │
    │  CHECK(region NOT EMPTY)                                            │
    └──────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│                         entity_idempotency                               │
├─────────────────────────────────────────────────────────────────────────┤
│  PK: (event_id, entity_id)  UUID, UUID                                  │
│  event_type                 VARCHAR(255) NOT NULL                       │
│  processed_at               TIMESTAMPTZ NOT NULL DEFAULT NOW()         │
├─────────────────────────────────────────────────────────────────────────┤
│  TTL: 7 days (pruned via prune_idempotency_records())                   │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│                           event_outbox                                   │
│                              (ENT-01)                                   │
│  Used to publish entity.EntityCreated events atomically within the      │
│  same database transaction as the entity insert (transactional outbox). │
└─────────────────────────────────────────────────────────────────────────┘
```

### Generated Column: `data_residency_zone`

The `data_residency_zone` column is computed automatically from the `region` column using an immutable PostgreSQL function:

| Region | Data Residency Zone |
|--------|-------------------|
| `us-east-1`, `us-west-2` | `us-east-1` |
| `eu-west-1`, `eu-central-1`, `eu-west-2` | `eu-west-1` |
| `ap-southeast-1`, `ap-southeast-2` | `ap-southeast-1` |
| `ap-northeast-1`, `ap-northeast-2` | `ap-northeast-1` |
| `sa-east-1` | `sa-east-1` |
| `me-south-1`, `af-south-1` | `me-af-1` |
| *any other region* | *returns the region itself* |

This enables efficient data-residency-aware querying without application logic.

---

## 3. Entity Status Lifecycle

```
    ┌─────────────┐
    │ provisioning│  (initial state for async provisioning)
    └──────┬──────┘
           │
           ▼
    ┌─────────────┐
    │   active    │◄────────────────────────────┐
    └──────┬──────┘                             │
           │                                    │
           ▼                                    │
    ┌─────────────┐                             │
    │  inactive   │─────────────────────────────┘
    └──────┬──────┘  (can be reactivated)
           │
           ▼
    ┌─────────────┐
    │   deleted   │  (soft-delete — record preserved)
    └─────────────┘
```

---

## 4. Event Contract

### `entity.EntityCreated`

**Owner:** EntityManagement  
**Consumers:** ServiceRegistry (via ACL), AuditLog, SearchIndex  
**Format:** CloudEvents (via transactional outbox)

```json
{
  "event_id": "018f3e6a-9b5c-7a00-8000-000000000001",
  "event_type": "entity.EntityCreated",
  "source": "entity-management",
  "subject": "entity/a1000001-0000-4000-8000-000000000001",
  "data": {
    "entityId": "a1000001-0000-4000-8000-000000000001",
    "entityName": "api-gateway",
    "entityType": "ServiceComponent",
    "region": "us-east-1",
    "status": "active",
    "createdAt": "2026-06-03T12:00:00Z",
    "schemaVersion": 1
  }
}
```

### Payload Mapping

| Event Field | Source | Description |
|-------------|--------|-------------|
| `entityId` | `entities.id` | Generated UUID |
| `entityName` | `entities.name` | User-provided name |
| `entityType` | `entities.type` | Derived from schema name |
| `region` | `entities.region` | Deployment region |
| `status` | `entities.status` | Lifecycle status |
| `createdAt` | `entities.created_at` | Creation timestamp |
| `schemaVersion` | `entities.schema_version` | Schema version used |

---

## 5. Validation Rules

### Schema-Level Validation (checked before DB write)

1. **Schema must exist and be active** — The referenced `schema_id` must point to an active entity schema
2. **Required fields** — All fields marked `required = true` in the schema must be present in the payload
3. **Field types** — Values must match the declared field type (string, enum, map, etc.)
4. **Enum constraints** — Values for `enum` fields must be one of the allowed values
5. **String constraints** — Length, pattern, etc. must match
6. **Number constraints** — Min/max range must be satisfied
7. **Unique name per schema** — `(schema_id, name)` must be unique

### Database-Level Constraints

| Constraint | Enforcement | Error |
|------------|-------------|-------|
| `schema_id` FK | Foreign key | `foreign_key_violation` → 400 |
| `UNIQUE(schema_id, name)` | Unique index | `unique_violation` → 409 |
| `name NOT EMPTY` | Check | `check_violation` → 400 |
| `region NOT EMPTY` | Check | `check_violation` → 400 |
| `NOT NULL` on required columns | Schema | `not_null_violation` → 400 |

---

## 6. Index Strategy

| Table | Index | Type | Rationale |
|-------|-------|------|-----------|
| `entities` | `(schema_id)` | B-tree | Fast lookup of all entities for a schema |
| `entities` | `(schema_id, status)` | Composite B-tree | Filtered list by schema + status |
| `entities` | `(region, status)` | Composite B-tree | Region-scoped queries |
| `entities` | `(data_residency_zone)` | B-tree | Data-residency-aware queries (generated column) |
| `entities` | `(type)` | B-tree | Grouping/filtering by schema type name |
| `entities` | `(status)` | B-tree | Lifecycle-based queries |
| `entities` | `(created_at DESC)` | B-tree | Default chronological listing |
| `entities` | `(name)` GIN trgm | GIN trigram | Full-text search on entity name |
| `entities` | `(attributes)` GIN | GIN jsonb_path_ops | Querying dynamic schema attributes |
| `entities` | `(schema_id, status, created_at DESC)` | Composite B-tree | Paginated listing with filters |
| `entity_idempotency` | `(processed_at)` | Partial B-tree | Efficient TTL-based cleanup |
| `entity_schema_fields` | `(schema_id, required)` | Composite B-tree | Find required fields for validation |

---

## 7. API Endpoint

### `POST /api/v1/entities`

**Request Body:**
```json
{
  "name": "api-gateway",
  "region": "us-east-1",
  "status": "active"
}
```

**Schema resolution:** The schema is identified by the `slug` derived from the entity type (e.g., `service-component` for "ServiceComponent"), or passed explicitly as `schema_id` or `schema_slug` in the request body.

**Response (201 Created):**
```json
{
  "id": "a1000001-0000-4000-8000-000000000001",
  "schema_id": "f0000001-0000-4000-8000-000000000001",
  "schema_version": 1,
  "name": "api-gateway",
  "type": "ServiceComponent",
  "region": "us-east-1",
  "data_residency_zone": "us-east-1",
  "status": "active",
  "attributes": {},
  "created_at": "2026-06-03T12:00:00Z",
  "updated_at": "2026-06-03T12:00:00Z"
}
```

**Error Responses:**

| HTTP Status | Condition | Example Error |
|-------------|-----------|---------------|
| 400 | Missing required field | `{"error": "validation_error", "details": [{"field": "name", "reason": "is required"}]}` |
| 400 | Invalid enum value | `{"error": "validation_error", "details": [{"field": "region", "reason": "must be one of: us-east-1, eu-west-1, us-west-2", "value": "ap-southeast-1"}]}` |
| 404 | Schema not found | `{"error": "not_found", "message": "Entity schema 'ServiceComponent' not found"}` |
| 409 | Duplicate name | `{"error": "conflict", "message": "Entity with name 'api-gateway' already exists in this schema"}` |

---

## 8. Caching Strategy (Redis)

### Cache Key Structure

| Key Pattern | Type | TTL | Description |
|-------------|------|-----|-------------|
| `entity:{entity_id}` | String (JSON) | 5 min | Full entity instance |
| `entity:list:{schema_id}:{status}:{page}` | String (JSON) | 2 min | Paginated entity list |
| `entity:list:region:{region}:{page}` | String (JSON) | 2 min | Entities by region |
| `entity:count:{schema_id}:{status}` | String (int) | 2 min | Entity counts |
| `entity:zone:{data_residency_zone}` | Set | 5 min | Entities by residency zone |
| `entity:version:{entity_id}` | String (TS) | No expiry | Cache version for invalidation |

### Invalidation Strategy

- **Write-through on create**: After inserting an entity, invalidate all list caches for the schema and region
- **Write-through on update/delete**: Invalidate the entity's individual cache key and affected lists
- **Pattern-based invalidation**: Use `SCAN` or maintain a set of cache keys per schema for bulk invalidation
- **Version-based**: A schema version change invalidates all cached entities for that schema

---

## 9. Idempotency & Event Deduplication

The `entity_idempotency` table provides idempotent event processing guarantees:

1. **7-day TTL**: Records are automatically pruned after 7 days by the `prune_idempotency_records()` function
2. **Primary key**: `(event_id, entity_id)` — prevents duplicate event processing
3. **Usage**: Before processing an `EntityCreated` event, consumers check this table. If the record exists, the event is skipped.

---

## 10. Error Codes

| HTTP Status | Error Code | Description |
|-------------|------------|-------------|
| 400 | `ERR_MISSING_REQUIRED_FIELD` | A required schema field is missing |
| 400 | `ERR_INVALID_ENUM_VALUE` | Value not in allowed enum set |
| 400 | `ERR_INVALID_FIELD_TYPE` | Value doesn't match field type |
| 400 | `ERR_CONSTRAINT_VIOLATION` | Field violates a constraint (min/max/pattern) |
| 400 | `ERR_SCHEMA_INACTIVE` | Referenced schema is not active |
| 404 | `ERR_SCHEMA_NOT_FOUND` | Schema not found by ID or slug |
| 409 | `ERR_DUPLICATE_ENTITY_NAME` | Entity name already exists in this schema |
| 500 | `ERR_EVENT_PUBLISH_FAILED` | Failed to enqueue EntityCreated event |

---

## 11. Migration Files

| File | Description |
|------|-------------|
| `docs/migrations/003_create_entities.sql` | DDL for entities, entity_idempotency tables, and supporting functions |
| `docs/seeds/003_entity_data.sql` | ServiceComponent schema definition + sample entities + events |
| `docs/deploy/redis/entity_redis.conf` | Redis caching configuration for entity instances |

---

## 12. Related ADRs

- **ADR-002**: Eventing Strategy — Transactional outbox pattern (PostgreSQL-backed)
- The `event_outbox` table from migration 002 is used to publish `EntityCreated` events
- The `entity_idempotency` table provides exactly-once processing guarantees for event consumers
