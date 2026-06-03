# ENT-03: Update Entity

> **Story:** ENT-03 — Update Entity  
> **Status:** ✅ Implemented (Migration + Seed)  
> **Domain:** Entity Management (Core Domain)  
> **Event:** `entity.EntityUpdated`  
> **Owners:** EntityManagement  
> **Consumers:** ServiceRegistry, AuditLog, CacheInvalidation  
> **Depends on:** ENT-01 (entity_schemas, event_outbox), ENT-02 (entities table)
> **Migration:** `docs/migrations/004_update_entities.sql`
> **Seed:** `docs/seeds/004_entity_update_data.sql`

---

## 1. Overview

Users can modify an existing entity's mutable fields — `name`, `status`, `attributes`, `metadata`, and `schema_version`. Immutable fields (`id`, `region`, `type`, `schema_id`, `created_at`, `data_residency_zone`) are rejected at both the application layer and database layer via a `BEFORE UPDATE` trigger.

Each update is:
1. Validated against immutable field constraints
2. Captured in the `entity_audit_log` table (before/after snapshots)
3. Published as an `entity.EntityUpdated` event via the transactional outbox

### Gherkin Acceptance Criteria

```gherkin
Feature: Entity Update
  Scenario: Successfully update entity status
    Given an existing entity with id "ent-123" and status "active"
    When I PUT /api/v1/entities/ent-123 with payload { "status": "inactive", "metadata": { "deprecated_at": "2025-01-15" } }
    Then the response is 200 OK
    And the entity's status is updated to "inactive"
    And an entity.EntityUpdated event is emitted with changed fields

  Scenario: Update non-existent entity
    Given no entity exists with id "ent-999"
    When I PUT /api/v1/entities/ent-999
    Then the response is 404 Not Found
    And no event is published

  Scenario: Attempt to mutate immutable field
    Given an entity with region "us-east-1"
    When I PUT /api/v1/entities/ent-123 with payload { "region": "eu-west-1" }
    Then the response is 422 Unprocessable Entity
    And the error indicates region is immutable after creation
```

---

## 2. Database Schema Changes

### New Table: `entity_audit_log`

This table provides an immutable, append-only audit trail of every entity update.

```sql
CREATE TABLE entity_audit_log (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id       UUID NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    event_id        UUID NOT NULL REFERENCES event_outbox(event_id) ON DELETE RESTRICT,

    -- Before/after snapshots
    previous_state  JSONB NOT NULL,           -- Full entity state BEFORE the update
    new_state       JSONB NOT NULL,           -- Full entity state AFTER the update
    changed_fields  TEXT[] NOT NULL,          -- e.g., {'status', 'metadata'}

    -- Audit metadata
    updated_by      VARCHAR(255),             -- User/principal making the change
    source_ip       INET,                     -- Client IP address
    user_agent      TEXT,                     -- HTTP User-Agent

    logged_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT ck_entity_audit_log_changed_fields_not_empty
        CHECK (cardinality(changed_fields) > 0)
);
```

### Modified Table: `entities` (from ENT-02)

| Change | Description |
|--------|-------------|
| ADD COLUMN `metadata JSONB` | New column for storing arbitrary key-value metadata (Gherkin: `{ "deprecated_at": "2025-01-15" }`) |

### Entity-Relationship Diagram (Updated)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              entities                                        │
│                                (ENT-02)                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│  PK: id              UUID      DEFAULT gen_random_uuid()                    │
│  schema_id           UUID      NOT NULL → entity_schemas(id)                │
│  schema_version      INTEGER   NOT NULL DEFAULT 1                           │
│  name                VARCHAR   NOT NULL                                      │
│  type                VARCHAR   NOT NULL                                      │
│  region              VARCHAR   NOT NULL  ← IMMUTABLE after creation         │
│  status              ENUM      NOT NULL DEFAULT 'active'                     │
│  data_residency_zone TEXT      GENERATED (immutable, derived from region)   │
│  attributes          JSONB     NOT NULL DEFAULT '{}'                         │
│  metadata            JSONB     NOT NULL DEFAULT '{}'  ← NEW in ENT-03      │
│  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()  ← IMMUTABLE        │
│  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()  ← AUTO-UPDATED     │
└──────────────────────────────┬──────────────────────────────────────────────┘
                               │ 1
                               │
                               │ * (FK: entity_id)
    ┌──────────────────────────▼──────────────────────────────────────────────┐
    │                          entity_audit_log                                │
    │                               (ENT-03)                                   │
    ├──────────────────────────────────────────────────────────────────────────┤
    │  PK: id              UUID      DEFAULT gen_random_uuid()                │
    │  entity_id           UUID      NOT NULL → entities(id)                  │
    │  event_id            UUID      NOT NULL → event_outbox(event_id)        │
    │  previous_state      JSONB     NOT NULL (full snapshot before update)   │
    │  new_state           JSONB     NOT NULL (full snapshot after update)    │
    │  changed_fields      TEXT[]    NOT NULL (list of modified field names)  │
    │  updated_by          VARCHAR(255)  (user/principal)                     │
    │  source_ip           INET         (client IP)                           │
    │  user_agent          TEXT                                                │
    │  logged_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()                 │
    ├──────────────────────────────────────────────────────────────────────────┤
    │  Immutable (INSERT-only, no UPDATE/DELETE triggers)                     │
    └──────────────────────────────────────────────────────────────────────────┘

    ┌──────────────────────────────────────────────────────────────────────────┐
    │                        event_outbox (ENT-01)                             │
    │  Extended in ENT-03 to support entity.EntityUpdated events               │
    └──────────────────────────────────────────────────────────────────────────┘
```

### Mutable vs Immutable Fields

| Field | Mutable? | Notes |
|-------|----------|-------|
| `id` | ❌ No | Primary key, assigned at creation |
| `schema_id` | ❌ No | Schema binding is permanent |
| `schema_version` | ✅ Yes | Can be bumped on schema migration |
| `name` | ✅ Yes | Managed by unique constraint per schema |
| `type` | ❌ No | Denormalized from schema name, cannot change |
| `region` | ❌ No | Determines data residency zone (Gherkin: 422) |
| `data_residency_zone` | ❌ No | Generated column from region |
| `status` | ✅ Yes | Lifecycle state (active↔inactive→deleted) |
| `attributes` | ✅ Yes | Dynamic schema-defined attributes |
| `metadata` | ✅ Yes | Arbitrary key-value metadata (NEW) |
| `created_at` | ❌ No | Immutable creation timestamp |
| `updated_at` | 🔄 Auto | Set by `update_modified_column()` trigger |

---

## 3. Trigger Architecture

The update pipeline consists of three triggers that fire in sequence:

```
UPDATE entities SET status = 'inactive', metadata = '{"deprecated_at": "2025-01-15"}'
    │
    │  BEFORE UPDATE
    │
    ├─▶ Trigger 1: prevent_entity_immutable_field_update
    │   └─ Checks: id, region, type, schema_id, created_at unchanged
    │   └─ On violation: RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD'
    │
    ├─▶ Trigger 2: update_entities_modtime (from ENT-02 migration)
    │   └─ Sets updated_at = NOW()
    │
    │  AFTER UPDATE
    │
    └─▶ Trigger 3: after_entity_update
        ├─ 1. log_entity_update()
        │   └─ Compares OLD.* vs NEW.*
        │   └─ Computes changed_fields TEXT[]
        │   └─ INSERT INTO entity_audit_log (...)
        │   └─ Sets session-local context (event_id, changed_fields)
        │
        └─ 2. enqueue_entity_updated_event()
            └─ Reads session-local context
            └─ INSERT INTO event_outbox (event_type='entity.EntityUpdated', ...)
            └─ Clears session-local context
```

### Why Two AFTER Triggers Instead of One?

The design uses a single trigger function (`log_entity_update`) that internally handles both audit logging and event enqueuing. This guarantees:

1. **Atomic event_id** — Same UUID is used for both the audit log and outbox
2. **Atomicity** — Both writes happen in the same trigger execution
3. **No trigger ordering dependency** — Single function avoids cross-trigger ordering issues

### Immutable Field Enforcement (Defense in Depth)

| Layer | Enforcement | Behavior |
|-------|-------------|----------|
| **API** (Application) | Input validation | Returns 422 with field name |
| **Repository** (Application) | Partial update builder | Silently strips immutable fields |
| **Database** (PostgreSQL) | `BEFORE UPDATE` trigger | Raises `ERR_IMMUTABLE_FIELD` exception |

The database-level trigger is a **defense-in-depth** measure. It should never fire in normal operation (application prevents it), but protects against:

- Direct SQL mutations
- Buggy application code
- Migration scripts that accidentally modify immutable fields

---

## 4. Event Contract

### `entity.EntityUpdated`

**Owner:** EntityManagement  
**Consumers:** ServiceRegistry, AuditLog, CacheInvalidation  
**Format:** CloudEvents (via transactional outbox)

```json
{
  "event_id": "018f3e6a-9b5c-7a00-8000-000000000001",
  "event_type": "entity.EntityUpdated",
  "source": "entity-management",
  "subject": "entity/a1000001-0000-4000-8000-000000000001",
  "data": {
    "entityId": "a1000001-0000-4000-8000-000000000001",
    "entityName": "api-gateway",
    "entityType": "ServiceComponent",
    "region": "us-east-1",
    "previousState": {
      "name": "api-gateway",
      "status": "active",
      "attributes": {
        "owner": "platform-team",
        "version": "2.1.3"
      },
      "metadata": {},
      "schemaVersion": 1,
      "updatedAt": "2025-01-14T12:00:00Z"
    },
    "newState": {
      "name": "api-gateway",
      "status": "inactive",
      "attributes": {
        "owner": "platform-team",
        "version": "2.1.3"
      },
      "metadata": {
        "deprecated_at": "2025-01-15"
      },
      "schemaVersion": 1,
      "updatedAt": "2025-01-15T10:30:00Z"
    },
    "changedFields": ["status", "metadata"],
    "updatedAt": "2025-01-15T10:30:00Z"
  }
}
```

### Payload Mapping

| Event Field | Source | Description |
|-------------|--------|-------------|
| `entityId` | `NEW.id` | Entity UUID |
| `entityName` | `NEW.name` | Current entity name |
| `entityType` | `NEW.type` | Denormalized schema name |
| `region` | `NEW.region` | Deployment region |
| `previousState` | Computed from OLD row | Full snapshot before update |
| `newState` | Computed from NEW row | Full snapshot after update |
| `changedFields` | Computed diff | Array of modified field names |
| `updatedAt` | `NEW.updated_at` | Timestamp of update |

### Consumer Responsibilities

| Consumer | Action |
|----------|--------|
| **ServiceRegistry** (via ACL) | Updates service registry entries for the entity |
| **AuditLog** | Persists the event payload as an immutable audit trail |
| **CacheInvalidation** | Invalidates Redis cache entries for the entity and affected list views |

---

## 5. Audit Log Usage

### Helper Functions

#### `get_entity_update_history(entity_id, limit)`

Returns the most recent update entries for an entity:

```sql
SELECT * FROM get_entity_update_history('a1000001-0000-4000-8000-000000000001', 5);

-- Returns:
--  audit_log_id | changed_fields | previous_state | new_state | logged_at
--  -------------+----------------+----------------+-----------+-----------
--  abc...       | {status,metadata} | {...}       | {...}     | 2025-01-15 10:30:00
--  def...       | {name}         | {...}          | {...}     | 2025-01-14 09:15:00
```

#### `get_entity_changed_fields_since(entity_id, since_timestamp)`

Returns all fields that changed since a given timestamp:

```sql
SELECT * FROM get_entity_changed_fields_since(
    'a1000001-0000-4000-8000-000000000001',
    NOW() - INTERVAL '1 hour'
);

-- Returns:
--  changed_fields | changed_at
--  ---------------+-----------
--  {status,metadata} | 2025-01-15 10:30:00
```

### Audit Log Retention

The `entity_audit_log` table grows unboundedly. The following strategies are recommended:

1. **Application-level retention policy**: Archive entries older than 90 days to cold storage
2. **Partitioning**: Partition by `logged_at` (monthly) for efficient pruning
3. **TTL via pg_cron**: Daily job to move entries older than 90 days to an archive table

---

## 6. Index Strategy

### New Indexes (ENT-03)

| Table | Index | Type | Rationale |
|-------|-------|------|-----------|
| `entity_audit_log` | `(entity_id, logged_at DESC)` | Composite B-tree | Fast lookup: all updates for an entity, newest first |
| `entity_audit_log` | `(changed_fields)` | GIN | Find updates that modified specific fields |
| `entity_audit_log` | `(logged_at DESC)` | B-tree | Chronological queries across all entities |
| `entity_audit_log` | `(event_id)` | B-tree | Join with event_outbox for traceability |
| `entities` | `(updated_at DESC)` | B-tree | Recent updates across all entities |
| `entities` | `(schema_id, status, updated_at DESC)` | Composite B-tree | Paginated updates by schema + status |

### Existing Indexes (from ENT-01/ENT-02)

Refer to `docs/docs/ENT-02_create_entity.md` for the full index catalog.

---

## 7. Status Lifecycle (Updated)

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
    │   deleted   │  (soft-delete — terminal state)
    └─────────────┘
```

### Valid Transitions

| From | To | Notes |
|------|----|-------|
| `provisioning` | `active` | Provisioning complete |
| `active` | `inactive` | User deactivation (Gherkin scenario) |
| `active` | `deleted` | Soft-delete |
| `inactive` | `active` | Reactivation |
| `inactive` | `deleted` | Soft-delete from inactive |

---

## 8. API Endpoint

### `PUT /api/v1/entities/{id}`

**Request Body:**
```json
{
  "name": "api-gateway",
  "status": "inactive",
  "metadata": {
    "deprecated_at": "2025-01-15"
  },
  "attributes": {
    "owner": "platform-team"
  }
}
```

**Response (200 OK):**
```json
{
  "id": "a1000001-0000-4000-8000-000000000001",
  "schema_id": "f0000001-0000-4000-8000-000000000001",
  "schema_version": 1,
  "name": "api-gateway",
  "type": "ServiceComponent",
  "region": "us-east-1",
  "data_residency_zone": "us-east-1",
  "status": "inactive",
  "attributes": {
    "owner": "platform-team",
    "version": "2.1.3"
  },
  "metadata": {
    "deprecated_at": "2025-01-15"
  },
  "created_at": "2025-01-14T12:00:00Z",
  "updated_at": "2025-01-15T10:30:00Z"
}
```

**Error Responses:**

| HTTP Status | Error Code | Condition | Example Error |
|-------------|------------|-----------|---------------|
| 404 | `ERR_ENTITY_NOT_FOUND` | Entity ID does not exist | `{"error": "not_found", "message": "Entity with id 'ent-999' not found"}` |
| 422 | `ERR_IMMUTABLE_FIELD` | Attempt to mutate an immutable field | `{"error": "immutable_field", "message": "Field 'region' is immutable after creation", "field": "region"}` |
| 409 | `ERR_DUPLICATE_ENTITY_NAME` | Rename to a name that already exists in the schema | `{"error": "conflict", "message": "Entity with name 'api-gateway' already exists in this schema"}` |
| 400 | `ERR_VALIDATION_FAILED` | Invalid enum value or constraint violation | `{"error": "validation_error", "details": [{"field": "status", "reason": "must be one of: active, inactive, deleted, provisioning"}]}` |
| 422 | `ERR_INVALID_STATUS_TRANSITION` | Invalid status transition | `{"error": "invalid_status_transition", "message": "Cannot transition from 'deleted' to 'active'"}` |

---

## 9. Caching Strategy (Redis)

### Cache Key Updates (ENT-03 additions)

The following cache keys are invalidated on entity update:

| Key Pattern | Action on Update | Rationale |
|-------------|-----------------|-----------|
| `entity:{entity_id}` | DEL | Stale entity data |
| `entity:list:{schema_id}:*` | DEL (all pages) | Entity may appear in any page |
| `entity:list:region:{region}:*` | DEL (all pages) | Region-based list views |
| `entity:version:{entity_id}` | INCR | Bump version for stale detection |
| `entity:count:{schema_id}:{status}` | DEL (old + new status) | Count may change on status transition |
| `entity:zone:{data_residency_zone}` | DEL (if keys in set) | Zone-based sets |

### Write-Through Invalidation Flow

```
PUT /api/v1/entities/ent-123
    │
    ├─▶ 1. Update entity in PostgreSQL
    │     (triggers audit log + EventUpdated outbox event)
    │
    ├─▶ 2. DEL entity:ent-123
    │
    ├─▶ 3. SCAN 0 MATCH entity:list:f0000001-* → [keys...]
    │     DEL [keys...]
    │
    ├─▶ 4. INCR entity:version:ent-123
    │
    └─▶ 5. PUBLISH entity:update:ent-123 "{...}"
          (cross-instance invalidation)
```

### Lazy Invalidation (Read-Repair)

```python
def get_entity(entity_id):
    cached = redis.get(f"entity:{entity_id}")
    if cached:
        version = cached.get("version")
        current_version = redis.get(f"entity:version:{entity_id}")
        if version == current_version:
            return cached  # Cache hit — fresh data
        # Cache hit — stale data: fall through to DB
    entity = db.query("SELECT * FROM entities WHERE id = ?", entity_id)
    if entity:
        redis.setex(f"entity:{entity_id}", 300, entity.to_json())
        redis.incr(f"entity:version:{entity_id}")
    return entity
```

---

## 10. Validation Rules

### Field-Level Validation (checked before DB write)

| Field | Validator | Notes |
|-------|-----------|-------|
| `name` | Schema field validation | Must match pattern, length constraints |
| `status` | Enum validation + transition check | Must be valid enum + valid transition from current status |
| `attributes` | Schema field validation | Each attribute validated against schema field definition |
| `metadata` | JSONB (no schema validation) | Free-form key-value pairs |
| `region` | ❌ Rejected at API layer | Immutable — returns 422 |
| `type` | ❌ Rejected at API layer | Immutable — returns 422 |

### Status Transition Validation

The application layer must call `EntityStatus.CanTransitionTo(target)` before updating:

```go
// From entity-management/internal/domain/types.go
func (s EntityStatus) CanTransitionTo(target EntityStatus) bool {
    for _, t := range s.ValidTransitions() {
        if t == target {
            return true
        }
    }
    return false
}
```

### Idempotency

The `entity_idempotency` table (from ENT-02) provides idempotency for event consumers processing `EntityUpdated` events:

1. Consumer receives `EntityUpdated` event
2. Checks `entity_idempotency` for `(event_id, entity_id)` pair
3. If exists: skip (already processed)
4. If not exists: process → insert idempotency record → mark outbox as processed

---

## 11. Migration Files

| File | Description |
|------|-------------|
| `docs/migrations/004_update_entities.sql` | Adds metadata column, entity_audit_log table, immutable field trigger, audit + outbox triggers, helper functions |
| `docs/seeds/004_entity_update_data.sql` | Demonstrates entity update scenarios, audit log entries, and outbox events |
| `docs/config/redis-entity-update.conf` | Redis caching configuration with update invalidation strategy |

---

## 12. Migration Dependencies

```
ENT-01 ──▶ ENT-02 ──▶ ENT-03
┌──────────┐  ┌──────────┐  ┌──────────────┐
│entity    │  │entities  │  │entity_audit  │
│_schemas  │  │          │  │_log          │
│entity    │  │entity_   │  │metadata col  │
│_schema   │  │idempotency│  │immutable     │
│_fields   │  │          │  │field trigger │
│event_    │  │          │  │+ EntityUpdated│
│outbox    │  │          │  │outbox events  │
└──────────┘  └──────────┘  └──────────────┘
```

---

## 13. Error Codes

| HTTP Status | Error Code | Description |
|-------------|------------|-------------|
| 404 | `ERR_ENTITY_NOT_FOUND` | Entity ID not found |
| 422 | `ERR_IMMUTABLE_FIELD` | Attempted to change an immutable field |
| 422 | `ERR_INVALID_STATUS_TRANSITION` | Invalid status transition |
| 400 | `ERR_VALIDATION_FAILED` | Schema validation failure (field type, enum, constraint) |
| 409 | `ERR_DUPLICATE_ENTITY_NAME` | Entity name already exists in schema |
| 500 | `ERR_EVENT_PUBLISH_FAILED` | Failed to enqueue EntityUpdated event |

---

## 14. Related ADRs

- **ADR-002**: Eventing Strategy — Transactional outbox pattern
- **ADR-005**: Data Residency — Region-based data residency zones (enforced via immutable field)
- The `event_outbox` table from ENT-01 is extended in ENT-03 to support `EntityUpdated` events
- The `entity_audit_log` table provides immutable audit trail for the AuditLog consumer
