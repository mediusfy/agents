

# ENTITYMGMT-07: User Restores a Soft-Deleted Entity to Active State

## Story

As a user, I want to restore a soft-deleted entity so that it becomes active again and visible in standard queries.

## Gherkin Scenarios

### SCENARIO 1: Successful restore of soft-deleted entity
```
Given entity "ent-001" is soft-deleted (deleted_at = "2024-01-15T10:00:00Z", status="deleted")
When a POST /api/v1/entities/ent-001/restore request is sent
Then deleted_at is cleared (set to NULL)
  And status transitions to "active"
  And an entitymanagement.entity.restored event is written to the outbox
  And HTTP 200 is returned with {"status": "restored", "entity_id": "ent-001"}
  And the entity is now visible in standard list queries
```

### SCENARIO 2: Restore of non-deleted entity is rejected
```
Given entity "ent-002" is active (deleted_at is NULL)
When a restore is attempted on entity "ent-002"
Then ErrNotDeleted is returned (HTTP 400)
  And message: "entity is not soft-deleted"
  And no data is modified
  And no entity.restored event is emitted
```

## Domain Event

**`entitymanagement.entity.restored`** — Published when a soft-deleted entity is restored.

| Field | Type | Description |
|-------|------|-------------|
| `event_id` | UUID | Unique event identifier |
| `entity_id` | UUID | The restored entity's ID |
| `entity_name` | String | Entity name at time of restore |
| `region` | String | Cloud provider region |
| `previous_deleted_at` | Timestamp | The original soft-delete timestamp (preserved before clearing) |
| `occurred_at` | Timestamp | When the restore occurred |

### Consumers
- **SearchContext** — Re-index the entity in search engine
- **BillingContext** — Resume billing for the entity if applicable
- **AuditLog** — Record the restoration for compliance

## Database Migration (ENTITYMGMT-07)

### Prerequisites
- ENTITYMGMT-05_000_soft_delete_restore (base restore functions)
- ENTITYMGMT-04_000_entity_update_optimistic (immutable field trigger)
- ENTITYMGMT-02_000_create_entities (entities table)

### What Changed

| Artifact | File | Description |
|----------|------|-------------|
| UP Migration | `ENTITYMGMT-07_000_restore_entity_refinement.up.sql` | Refines restore functions to match Gherkin spec |
| DOWN Migration | `ENTITYMGMT-07_000_restore_entity_refinement.down.sql` | Reverts to ENTITYMGMT-05 baseline |
| Queries | `ENTITYMGMT-07_restore_entity.sql` | Query patterns for restore workflow |
| Seed | `ENTITYMGMT-07_000_restore_entity_refinement_seed.sql` | Comprehensive test data for both scenarios |

### Functions Refined (from ENTITYMGMT-05 baseline)

1. **`restore_entity()`** — Now captures `previous_deleted_at` before clearing it. Returns it in the result for outbox event payload. Error message matches Gherkin: "entity is not soft-deleted".

2. **`enqueue_entity_restored_event()`** — Payload now includes `previous_deleted_at` (per Gherkin spec) instead of `restored_at`. Signature changed: `p_restored_at` → `p_previous_deleted_at`.

3. **`restore_entity_with_outbox()`** — Threads `previous_deleted_at` from restore into the outbox event. Returns `previous_deleted_at` in result set.

### New Functions

4. **`row_to_entity_restore_json(entities, TIMESTAMPTZ)`** — Extended helper that returns entity JSON including `previous_deleted_at`.

5. **`validate_entity_restorable(UUID)`** — Read-only pre-check. Returns `restorable=TRUE` for soft-deleted entities, `ERR_NOT_DELETED` with message "entity is not soft-deleted" for active entities.

6. **`get_restorable_entity(UUID)`** — Returns soft-deleted entity details with human-readable `deleted_duration` for restore UI display.

7. **`verify_entity_visible_after_restore(UUID, UUID)`** — Diagnostic that runs 5 checks to validate the entity is visible in standard list queries after restore.

### New Indexes
- `idx_entities_schema_deleted_recent` — schema_id + deleted_at DESC for restore lists
- `idx_entities_region_deleted` — region + deleted_at DESC for region-scoped restore
- `idx_entities_name_deleted` — name + deleted_at DESC for search-by-name within deleted
- `idx_entities_restore_lookup` — id + deleted_at for fast restore lookup

## API Endpoint

### `POST /api/v1/entities/{id}/restore`

**Success Response (SCENARIO 1):**
```json
HTTP 200 OK
{
    "status": "restored",
    "entity_id": "ent-001"
}
```

**Error Response (SCENARIO 2):**
```json
HTTP 400 Bad Request
{
    "code": "BAD_REQUEST",
    "message": "entity is not soft-deleted"
}
```

## Architecture

The restore follows the **transactional outbox pattern**:
1. Application `Service.RestoreEntity()` validates the entity is soft-deleted
2. Within a single DB transaction:
   - Captures `deleted_at` as `previous_deleted_at`
   - Clears `deleted_at`, sets `status='active'`, bumps `version`
   - Enqueues `entitymanagement.entity.restored` event with `previous_deleted_at`
3. Transaction commits → event is atomically persisted
4. Outbox relay publishes the event to downstream consumers

## Error Codes

| Error Code | HTTP Status | Message | Scenario |
|-----------|-------------|---------|----------|
| `ERR_NOT_DELETED` | 400 Bad Request | "entity is not soft-deleted" | SCENARIO 2 |
| `ERR_ENTITY_NOT_FOUND` | 404 Not Found | "Entity with ID ... not found" | Non-existent ID |
