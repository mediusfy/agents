

# ENTITYMGMT-05: Soft-Delete and Restore Entities

## Story
User soft-deletes an entity (setting deleted_at, transitioning to terminal status).

## Gherkin Scenarios

### SCENARIO 1: Successful soft-delete
- **Given** an active entity "ent-001" exists with status "active" and deleted_at is NULL
- **When** DELETE /api/v1/entities/ent-001 request is sent (soft-delete, no ?permanent param)
- **Then** deleted_at is set to current UTC timestamp
  - Status transitions to "deleted" (terminal)
  - entitymanagement.entity.soft_deleted event written to outbox within same transaction
  - HTTP 200 with {"status": "soft_deleted", "entity_id": "ent-001"}
  - Entity excluded from default list queries (include_deleted=false)

### SCENARIO 2: Idempotent re-delete rejected
- **Given** entity "ent-001" is already soft-deleted
- **When** a second soft-delete is attempted
- **Then** ErrAlreadyDeleted is returned (no duplicate event emitted)

### SCENARIO 3: Excluded from default listing
- **Given** a soft-deleted entity "ent-001"
- **When** a standard GET /api/v1/entities?schema_id=X is called
- **Then** entity "ent-001" is NOT included in results

## Database Changes

### Functions Created
| Function | Purpose |
|---|---|
| `row_to_entity_json(UUID)` | Serialize entity row to JSONB |
| `soft_delete_entity(UUID)` | Atomic soft-delete with validation |
| `enqueue_entity_soft_deleted_event(...)` | Outbox event enqueue |
| `soft_delete_entity_with_outbox(UUID, VARCHAR)` | Combined delete + event |
| `restore_entity(UUID)` | Atomic restore from soft-delete |
| `enqueue_entity_restored_event(...)` | Outbox event enqueue |
| `restore_entity_with_outbox(UUID, VARCHAR)` | Combined restore + event |

### Trigger Updates
- `prevent_immutable_field_update` updated to allow:
  - Soft-delete: `active`/`inactive` → `deleted` (with deleted_at set)
  - Restore: `deleted` → `active` (with deleted_at cleared)

### Indexes Added
- `idx_entities_deleted_at` — List soft-deleted entities
- `idx_entities_schema_active` — Schema-filtered active entities
- `idx_entities_schema_status_active` — Schema+status filtered active
- `idx_entities_region_active` — Region-scoped active entities
- `idx_entities_deleted_at_recent` — Recently deleted (7 days)
- `idx_entities_restorable` — Fast restore lookup
- `idx_entities_non_deleted` — Default list query index
- `idx_outbox_lifecycle_events` — Outbox lifecycle event relay

## Domain Events

### entitymanagement.entity.soft_deleted
- **Owned by:** EntityManagement
- **Payload:** `{event_id, entity_id, entity_name, region, deleted_at, previous_status, occurred_at}`
- **Consumers:** BillingContext, SearchContext, LifecycleContext, AuditLog
- **NOT emitted** on idempotent re-deletes (SCENARIO 2)

### entitymanagement.entity.restored
- **Owned by:** EntityManagement
- **Payload:** `{event_id, entity_id, entity_name, region, restored_at, previous_status, new_status, occurred_at}`
- **Consumers:** BillingContext (resume billing), SearchContext (re-index), AuditLog

## Error Codes
| Error | HTTP Status | Condition |
|---|---|---|
| `ERR_ALREADY_DELETED` | 409 Conflict | Second soft-delete on already-deleted entity |
| `ERR_ENTITY_NOT_FOUND` | 404 Not Found | Entity does not exist |
| `ERR_INVALID_STATUS_TRANSITION` | 400 Bad Request | Status doesn't allow deletion |
| `ERR_NOT_DELETED` | 400 Bad Request | Attempted restore on non-deleted entity |
