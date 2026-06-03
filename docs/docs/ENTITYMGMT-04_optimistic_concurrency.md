

# ENTITYMGMT-04: User Updates Entity with Optimistic Concurrency Control

## Story

As a platform engineer
I want to update an existing entity with optimistic concurrency control
So that concurrent modifications are detected and data integrity is preserved

## Gherkin Scenarios

### SCENARIO 1: Successful update
```
Given an entity "ent-001" exists with version 3
  And attributes: {"email": "old@example.com", "name": "Alice"}
When a PUT /api/v1/entities/ent-001 request is sent
  With body: {"expected_version": 3, "name": "Alice Updated", "attributes": {"email": "new@example.com"}}
Then the entity is updated
  And version is incremented from 3 to 4
  And updated_at is refreshed
  And an entitymanagement.entity.updated event is written to the outbox
  And the event payload includes changed_fields: ["name", "attributes.email"]
  And HTTP 200 is returned with the full updated entity
```

### SCENARIO 2: Stale version rejection
```
Given entity "ent-001" now has version 4 (concurrent update)
When a PUT /api/v1/entities/ent-001 request is sent with expected_version=3 (stale)
Then HTTP 409 Conflict is returned with ErrStaleVersion
  And no data is modified
  And no entity.updated event is emitted
```

### SCENARIO 3: Immutable field rejection
```
Given a PUT request includes an immutable field change like "region"
When the update is attempted
Then HTTP 400 Bad Request is returned with ErrImmutableField
  And no changes are persisted
```

## Domain Event

**entitymanagement.entity.updated** — Published when an entity is successfully updated via optimistic concurrency. NOT emitted on stale version conflicts (HTTP 409) or immutable field violations (HTTP 400).

Payload:
```json
{
  "event_id": "<uuid>",
  "entity_id": "ent-001",
  "entity_name": "Alice Updated",
  "status": "active",
  "region": "eu-west-1",
  "previous_version": 3,
  "new_version": 4,
  "changed_fields": ["name", "attributes.email"],
  "occurred_at": "<timestamp>"
}
```

Consumers: SearchIndexer, AuditLog, WebhookDispatcher, Analytics

## Database Migration: ENTITYMGMT-04_000_entity_update_optimistic

This migration adds:

### 1. Immutable Field Protection Trigger (`prevent_immutable_field_update`)
A BEFORE UPDATE trigger on the `entities` table that prevents modifications to:
- `id` — Primary key, never changes
- `region` — Determines data_residency_zone (Gherkin SCENARIO 3)
- `data_residency_zone` — Generated column derived from region
- `type` — Denormalized from schema at creation
- `schema_id` — Schema blueprint is fixed at creation
- `created_at` — Timestamp of creation, never changes
- `version` — Auto-managed by optimistic lock; only accepts `version = version + 1`

### 2. Outbox Event Function (`enqueue_entity_updated_event`)
Writes `entitymanagement.entity.updated` events to the `outbox_events` table with the complete payload including changed_fields, previous_version, new_version, previous_state, and new_state.

### 3. Atomic Update Function (`update_entity_optimistic`)
Performs the core optimistic concurrency update:
- SELECT FOR UPDATE to lock the row
- Version check: returns failure if expected_version doesn't match
- SET version = version + 1 with WHERE id = $1 AND version = $2
- Computes changed_fields with dot notation for nested attributes (e.g., `attributes.email`)
- Returns full entity JSON, previous/new version, and changed_fields

### 4. Combined Update with Outbox (`update_entity_with_outbox`)
Application-layer entry point that wraps:
1. Version validation
2. Optimistic update
3. Changed fields computation
4. Outbox event enqueue
All within a single database transaction.

Returns structured result: `(success, entity_json, previous_version, new_version, changed_fields, event_id, error_code, error_message)`

### 5. Diagnostic Functions
- `get_entity_by_id_with_version()` — Pre-update read with version
- `validate_entity_version()` — Quick version validation
- `check_entity_staleness()` — Human-readable staleness diagnostics
- `count_entity_updates_since_version()` — Update rate tracking

### 6. Indexes
- `idx_entities_id_version` — Composite index for optimistic concurrency WHERE clause
- `idx_entities_version_status` — Version+status queries
- `idx_entities_updated_at_id` — Updated_at + id composite for pagination

## Files

| File | Path |
|------|------|
| UP Migration | `database/migrations/ENTITYMGMT-04_000_entity_update_optimistic.up.sql` |
| DOWN Migration | `database/migrations/ENTITYMGMT-04_000_entity_update_optimistic.down.sql` |
| Queries | `database/queries/ENTITYMGMT-04_update_entity_optimistic.sql` |
| Seeds | `database/seeds/ENTITYMGMT-04_000_entity_update_optimistic_seed.sql` |

## Existing Code Coverage

The following existing code already supports this story:
- `domain/types.go`: `Entity.ApplyUpdate()`, `UpdateOperation`, `ErrStaleVersion`, `ErrImmutableField`, `EntityUpdated` domain event
- `domain/service.go`: `Service.UpdateEntity()` with optimistic concurrency
- `application/update_entity.go`: `UpdateEntityUseCase` with error mapping
- `ports/handlers.go`: `handleUpdateEntity` with HTTP 409/400 mapping
- `adapters/postgres/entity_repo.go`: `Update()` with WHERE id AND version
- `ports/event_publisher.go`: `PublishEntityUpdated()` with `entitymanagement.entity.updated` CloudEvents type
