

# ENTITY-04: Update Entity Instance with Optimistic Concurrency Control

> **Story:** ENTITY-04 — Update Entity Instance  
> **Status:** ✅ Implemented (Migration + Seed + Redis Config)  
> **Domain:** Entity Management (Core Domain)  
> **Event:** `entitymanagement.EntityUpdated`  
> **Owners:** EntityManagement  
> **Consumers:** ServiceRegistry, AuditLog, CacheInvalidation  
> **Depends on:** ENT-01 (entity_schemas, event_outbox), ENT-02 (entities table), ENT-03 (entity_audit_log, triggers)
> **Migration:** `docs/generated-app/default/database/migrations/ENTITY-04_000_optimistic_concurrency.up.sql`
> **Seed:** `docs/generated-app/default/database/seeds/ENTITY-04_000_optimistic_concurrency_seed.sql`
> **Redis Config:** `docs/config/redis-entity-update-optimistic.conf`

---

## 1. Overview

This story introduces **optimistic concurrency control** for entity updates. Every entity carries an integer `version` field that is atomically incremented on each successful update. When a platform engineer sends an update request, they must supply the expected version number. If the version matches the current database version, the update succeeds and the version is incremented. If the version is stale, the update is rejected with **HTTP 409 Conflict** and **no changes are applied**.

This follows the **optimistic locking** pattern: we assume conflicts are rare and detect them at write time, rather than holding locks during read operations.

### Gherkin Acceptance Criteria

```gherkin
Feature: Update Entity Instance
  As a platform engineer
  I want to update an entity's mutable fields with optimistic concurrency
  So that concurrent modifications are detected and data integrity is preserved

  Scenario: Successfully update an entity
    Given an existing entity with ID "ENT-456" at version 3
    When a platform engineer sends an update request with version = 3
         and a modified payload
    Then the entity is updated to version 4
    And a domain event entitymanagement.EntityUpdated is emitted
         via the transactional outbox
    And the response returns the updated entity at version 4

  Scenario: Reject stale version update
    Given an existing entity with ID "ENT-456" at version 3
    When a platform engineer sends an update request with version = 2 (stale)
    Then the request is rejected with 409 Conflict
    And no update is applied
```

---

## 2. Design Decisions

### Why Optimistic Concurrency (Not Pessimistic Locking)?

| Criterion | Optimistic Locking | Pessimistic Locking |
|-----------|-------------------|---------------------|
| **Read concurrency** | ✅ Unlimited concurrent readers | ✅ Unlimited concurrent readers |
| **Write concurrency** | ✅ First writer wins; others retry | ❌ Contention under high write load |
| **Stale read detection** | ✅ Detected at write time | ❌ No detection (locks prevent reads) |
| **Latency on conflict** | ❌ Requires retry | ✅ No retry for locked-out writers |
| **Deadlock risk** | ✅ None | ❌ Possible with lock ordering |
| **Best for** | Read-heavy, low-conflict workloads | Write-heavy, high-conflict workloads |

Entity management is a **read-heavy** bounded context with **low write contention** (multiple platform engineers rarely update the same entity simultaneously). Optimistic concurrency is the correct choice.

### Version as an Integer

- **Integer version** (monotonically increasing) — Clear semantics, easy to compare, supports delta calculations (`count_entity_updates_since_version`)
- **UUID version** would be harder to order and compare
- **Timestamp-based version** could have clock skew issues in distributed environments

### Version in the Database, Not Just the Application

The version check and increment happen atomically in PostgreSQL:

```sql
UPDATE entities
SET name = $1, status = $2, ..., version = version + 1, updated_at = NOW()
WHERE id = $3 AND version = $4
```

This is **atomic** — the `SELECT` and `UPDATE` are not separate operations. PostgreSQL guarantees that no two concurrent transactions can both see the same version and succeed. The `RETURNING` clause or `ROW_COUNT` check tells the application whether the update was applied.

---

## 3. Database Schema Changes

### Modified Table: `entities`

| Change | Description |
|--------|-------------|
| ADD COLUMN `version INTEGER NOT NULL DEFAULT 1` | Monotonically increasing optimistic lock version |

### New Functions

| Function | Purpose |
|----------|---------|
| `update_entity_optimistic()` | Atomic UPDATE with version check + increment |
| `update_entity_with_outbox()` | Combined update + outbox event enqueue |
| `get_entity_by_id_with_version()` | Read entity with version for pre-update display |
| `get_entity_with_schema_info_and_version()` | Read entity with version + schema info |
| `validate_entity_version()` | Pre-check version before full update |
| `check_entity_staleness()` | Diagnostic message for 409 responses |
| `count_entity_updates_since_version()` | Track update velocity for rate limiting |

### Updated Functions

| Function | Change |
|----------|--------|
| `prevent_immutable_field_update()` | Now also protects `version` from being set directly |
| `log_entity_update()` | Now includes `version` in before/after snapshots and `changed_fields` |
| `enqueue_entity_updated_event()` | Event type changed to `entitymanagement.EntityUpdated` (was `entity.EntityUpdated`) |

### New Indexes

| Table | Index | Type | Rationale |
|-------|-------|------|-----------|
| `entities` | `(id, version)` | Composite B-tree | Optimistic concurrency WHERE clause |
| `entities` | `(version)` | B-tree | Version-based queries and debugging |
| `entities` | `(version, status)` | Composite B-tree | Filtered version queries |

---

## 4. Optimistic Concurrency Flow

### Success Path (SCENARIO 1)

```
Platform Engineer                    Application Layer                    PostgreSQL
     │                                      │                               │
     │  PUT /entities/{id}                  │                               │
     │  { version: 3, status: "inactive" }  │                               │
     │─────────────────────────────────────>│                               │
     │                                      │  SELECT ... WHERE id = $1     │
     │                                      │──────────────────────────────>│
     │                                      │  Entity at version 3          │
     │                                      │<──────────────────────────────│
     │                                      │                               │
     │                                      │  UPDATE entities              │
     │                                      │  SET status = 'inactive',     │
     │                                      │      version = version + 1,   │
     │                                      │      updated_at = NOW()       │
     │                                      │  WHERE id = $1 AND version=3  │
     │                                      │──────────────────────────────>│
     │                                      │  1 row affected               │
     │                                      │<──────────────────────────────│
     │                                      │                               │
     │                                      │  [Trigger: after_entity_update]
     │                                      │  ├─ log_entity_update()       │
     │                                      │  │   → entity_audit_log       │
     │                                      │  └─ enqueue_entity_updated_event()
     │                                      │      → event_outbox           │
     │                                      │                               │
     │  200 OK { entity, version: 4 }       │                               │
     │<─────────────────────────────────────│                               │
```

### Stale Version Path (SCENARIO 2)

```
Platform Engineer                    Application Layer                    PostgreSQL
     │                                      │                               │
     │  PUT /entities/{id}                  │                               │
     │  { version: 2, status: "inactive" }  │                               │
     │─────────────────────────────────────>│                               │
     │                                      │  SELECT ... WHERE id = $1     │
     │                                      │──────────────────────────────>│
     │                                      │  Entity at version 3          │
     │                                      │<──────────────────────────────│
     │                                      │                               │
     │                                      │  UPDATE entities              │
     │                                      │  SET status = 'inactive',     │
     │                                      │      version = version + 1    │
     │                                      │  WHERE id = $1 AND version=2  │
     │                                      │──────────────────────────────>│
     │                                      │  0 rows affected!             │
     │                                      │<──────────────────────────────│
     │                                      │                               │
     │                                      │  [No trigger fires]           │
     │                                      │  [No audit log entry]         │
     │                                      │  [No outbox event]            │
     │                                      │                               │
     │  409 Conflict                        │                               │
     │  { error: "stale_version",           │                               │
     │    expected: 2, actual: 3,           │                               │
     │    message: "Entity has been         │                               │
     │     modified since last read." }     │                               │
     │<─────────────────────────────────────│                               │
```

---

## 5. Event Contract

### `entitymanagement.EntityUpdated`

**Owner:** EntityManagement  
**Consumers:** ServiceRegistry, AuditLog, CacheInvalidation  
**Format:** CloudEvents (via transactional outbox)

```json
{
  "event_id": "018f3e6a-9b5c-7a00-8000-000000000001",
  "event_type": "entitymanagement.EntityUpdated",
  "source": "entity-management",
  "subject": "entity/a1000001-0000-4000-8000-000000000001",
  "data": {
    "entityId": "a1000001-0000-4000-8000-000000000001",
    "entityName": "api-gateway",
    "entityType": "ServiceComponent",
    "region": "us-east-1",
    "previousVersion": 3,
    "newVersion": 4,
    "previousState": {
      "name": "api-gateway",
      "status": "active",
      "attributes": { "owner": "platform-team" },
      "metadata": {},
      "schemaVersion": 1,
      "version": 3,
      "updatedAt": "2025-01-14T12:00:00Z"
    },
    "newState": {
      "name": "api-gateway",
      "status": "inactive",
      "attributes": { "owner": "platform-team" },
      "metadata": { "deprecated_at": "2025-06-01" },
      "schemaVersion": 1,
      "version": 4,
      "updatedAt": "2025-01-15T10:30:00Z"
    },
    "changedFields": ["status", "metadata", "version"],
    "updatedAt": "2025-01-15T10:30:00Z"
  }
}
```

### Key Differences from ENT-03 Event

| Aspect | ENT-03 (`entity.EntityUpdated`) | ENTITY-04 (`entitymanagement.EntityUpdated`) |
|--------|--------------------------------|---------------------------------------------|
| Event type | `entity.EntityUpdated` | `entitymanagement.EntityUpdated` |
| Version info | ❌ Not included | ✅ `previousVersion`, `newVersion` |
| Full state | ✅ `previousState`, `newState` | ✅ `previousState`, `newState` (with version) |
| Changed fields | ✅ `changedFields` | ✅ `changedFields` (includes 'version') |

---

## 6. API Contract

### `PUT /api/v1/entities/{id}`

**Request Body:**
```json
{
  "version": 3,
  "status": "inactive",
  "metadata": {
    "deprecated_at": "2025-06-01"
  }
}
```

**Response (200 OK — SCENARIO 1):**
```json
{
  "id": "a1000001-0000-4000-8000-000000000001",
  "schema_id": "f0000001-0000-4000-8000-000000000001",
  "schema_version": 1,
  "name": "api-gateway",
  "type": "ServiceComponent",
  "region": "us-east-1",
  "status": "inactive",
  "version": 4,
  "attributes": {
    "owner": "platform-team"
  },
  "metadata": {
    "deprecated_at": "2025-06-01"
  },
  "created_at": "2025-01-14T12:00:00Z",
  "updated_at": "2025-01-15T10:30:00Z"
}
```

**Response (409 Conflict — SCENARIO 2):**
```json
{
  "error": "stale_version",
  "expected_version": 2,
  "actual_version": 3,
  "message": "Entity 'api-gateway' has been modified. Expected version 2 but current version is 3."
}
```

### Error Responses

| HTTP Status | Error Code | Condition |
|-------------|------------|-----------|
| 404 | `ERR_ENTITY_NOT_FOUND` | Entity ID does not exist |
| 409 | `ERR_STALE_VERSION` | Expected version does not match current version |
| 422 | `ERR_IMMUTABLE_FIELD` | Attempt to mutate an immutable field |
| 422 | `ERR_INVALID_STATUS_TRANSITION` | Invalid status transition |
| 400 | `ERR_VALIDATION_FAILED` | Schema validation failure |
| 500 | `ERR_EVENT_PUBLISH_FAILED` | Failed to enqueue EntityUpdated event |

---

## 7. Migration Timeline

```
ENT-01 ──▶ ENT-02 ──▶ ENT-03 ──▶ ENTITY-04
┌──────────┐  ┌──────────┐  ┌──────────────┐  ┌──────────────────┐
│entity    │  │entities  │  │entity_audit  │  │version column    │
│_schemas  │  │          │  │_log          │  │optimistic lock   │
│entity    │  │entity_   │  │metadata col  │  │functions         │
│_schema   │  │idempotency│  │immutable     │  │entitymanagement  │
│_fields   │  │          │  │field trigger │  │.EntityUpdated    │
│event_    │  │          │  │EntityUpdated │  │event             │
│outbox    │  │          │  │triggers      │  │Redis cache       │
└──────────┘  └──────────┘  └──────────────┘  └──────────────────┘
```

---

## 8. Testing Strategy

### Unit Tests (Domain Layer)

| Test Case | Gherkin | Expected |
|-----------|---------|----------|
| `ApplyUpdate` with matching version | SCENARIO 1 | Version incremented, fields updated |
| `ApplyUpdate` with stale version | SCENARIO 2 | Returns `ErrStaleVersion` |
| `ApplyUpdate` with invalid transition | — | Returns `ErrInvalidStatusTransition` |
| `EntityUpdated` event creation | SCENARIO 1 | Event contains correct `previousVersion`/`newVersion` |

### Integration Tests (Repository Layer)

| Test Case | Description |
|-----------|-------------|
| `update_entity_optimistic` success | Version matches → update applied, version incremented |
| `update_entity_optimistic` stale | Version mismatch → no rows affected |
| `update_entity_optimistic` concurrency | Two concurrent updates; one succeeds, one fails |
| `update_entity_with_outbox` | Combined update + outbox event in single transaction |
| Trigger chain | `after_entity_update` fires correct functions in order |

### End-to-End Tests

| Test Case | Steps |
|-----------|-------|
| Happy path | Read entity (get version) → Update with version → Verify version increment |
| Stale conflict | Read entity → Another update changes version → Update with old version → 409 |
| Concurrent update | Two clients update same entity simultaneously → One succeeds, one gets 409 |
| Immutable field + version | Attempt to set version directly → 422 |

---

## 9. Migration Files

| File | Description |
|------|-------------|
| `docs/generated-app/default/database/migrations/ENTITY-04_000_optimistic_concurrency.up.sql` | Adds version column, functions, updated triggers |
| `docs/generated-app/default/database/migrations/ENTITY-04_000_optimistic_concurrency.down.sql` | Reverts ENTITY-04 changes |
| `docs/generated-app/default/database/seeds/ENTITY-04_000_optimistic_concurrency_seed.sql` | Demonstrates both Gherkin scenarios |
| `docs/generated-app/default/database/queries/ENTITY-04_update_entity_optimistic.sql` | Query patterns for optimistic concurrency |
| `docs/config/redis-entity-update-optimistic.conf` | Redis caching with version-based stale detection |

---

## 10. Related ADRs

- **ADR-002**: Eventing Strategy — Transactional outbox pattern
- **ADR-005**: Data Residency — Region-based data residency zones
- The `event_outbox` table is extended to support `entitymanagement.EntityUpdated` events alongside the legacy `entity.EntityUpdated` events
