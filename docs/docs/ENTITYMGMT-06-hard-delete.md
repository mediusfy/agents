# ENTITYMGMT-06: Hard-Delete (Permanent Removal) of Soft-Deleted Entities

## Overview
**Story**: User permanently removes a soft-deleted entity (hard-delete)
**Bounded Context**: Entity Management
**Status**: Implemented

## Gherkin Scenarios

### SCENARIO 1: Successful hard-delete
```gherkin
Given entity "ent-001" is soft-deleted (deleted_at set, status="deleted")
When a DELETE /api/v1/entities/ent-001?permanent=true request is sent
Then the entity record is permanently removed from the database
  And an entitymanagement.entity.hard_deleted event is written to the outbox
  And HTTP 200 is returned with {"status": "hard_deleted", "entity_id": "ent-001"}
```

### SCENARIO 2: Active entity cannot be hard-deleted
```gherkin
Given entity "ent-002" is active (deleted_at is NULL)
When a hard-delete is attempted on entity "ent-002"
Then ErrNotDeleted is returned (HTTP 400)
  And message: "entity must be soft-deleted before hard deletion"
  And no data is modified
```

### SCENARIO 3: Non-existent entity returns 404
```gherkin
Given entity "ent-999" does not exist
When a hard-delete is attempted
Then HTTP 404 Not Found is returned
```

## Domain Event: entitymanagement.entity.hard_deleted

| Field            | Type        | Description                                   |
|------------------|-------------|-----------------------------------------------|
| event_id         | UUID        | Unique event identifier                       |
| entity_id        | UUID        | The permanently removed entity's ID            |
| entity_name      | string      | Entity name at time of deletion                |
| region           | string      | Entity region (e.g., "eu-west-1")             |
| deleted_at       | timestamptz | Original soft-delete timestamp                 |
| hard_deleted_at  | timestamptz | When permanent removal occurred                |
| occurred_at      | timestamptz | Event creation timestamp                       |

**Consumers**:
- **ComplianceContext**: Confirm GDPR/CCPA erasure compliance
- **AuditLog**: Permanent deletion record for audit trails
- **ResidencyContext**: Confirm regional data removal

## Database Changes

### Migration: ENTITYMGMT-06_000_hard_delete

**Functions Created:**

| Function | Purpose | Error Codes |
|----------|---------|-------------|
| `hard_delete_entity(UUID)` | Atomically removes a soft-deleted entity row | `ERR_NOT_DELETED`, `ERR_ENTITY_NOT_FOUND`, `ERR_INVALID_STATUS` |
| `enqueue_entity_hard_deleted_event(...)` | Writes `entitymanagement.entity.hard_deleted` to outbox | N/A |
| `hard_delete_entity_with_outbox(UUID)` | Combined hard-delete + outbox event in one transaction | Same as `hard_delete_entity` |
| `prune_orphaned_idempotency()` | Cleans up idempotency keys for hard-deleted entities | N/A |

**Indexes Added:**
- `idx_entities_hard_deletable` — Optimizes hard-delete lookup (id + deleted_at)
- `idx_entities_deleted_at_bulk_hard_delete` — Bulk retention policy purges
- `idx_entities_region_deleted` — Region-scoped GDPR erasure queries
- `idx_outbox_hard_deleted_events` — Outbox relay polling for hard_deleted events

**Cascading Cleanup:**
- `request_idempotency` rows are auto-deleted via `ON DELETE CASCADE` FK
- `outbox_events` rows are preserved (no FK — event history is immutable)

### Error Code → HTTP Status Mapping

| error_code           | HTTP Status | Description                                        |
|----------------------|-------------|----------------------------------------------------|
| NULL (success)       | 200         | Entity permanently removed                         |
| `ERR_NOT_DELETED`    | 400         | Entity is active; must soft-delete first           |
| `ERR_ENTITY_NOT_FOUND` | 404       | Entity does not exist                              |
| `ERR_INVALID_STATUS` | 409         | Inconsistent state (deleted_at set but status != 'deleted') |

## Files

| File | Purpose |
|------|---------|
| `entity-management/database/migrations/ENTITYMGMT-06_000_hard_delete.up.sql` | UP migration |
| `entity-management/database/migrations/ENTITYMGMT-06_000_hard_delete.down.sql` | DOWN migration |
| `entity-management/database/seeds/ENTITYMGMT-06_000_hard_delete_seed.sql` | Data seed for all 3 scenarios |
| `entity-management/database/queries/ENTITYMGMT-06_hard_delete.sql` | Query documentation |
