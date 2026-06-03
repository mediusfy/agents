

# ENTITYMGMT-08: Entity Status Lifecycle Enforcement

## Story
**System enforces entity status lifecycle: active ↔ inactive → deleted (terminal)**

## Lifecycle Diagram
```
                  ┌─────────────────────────────────────┐
                  │                                     │
                  v                                     │
    ┌────────┐         ┌──────────┐         ┌────────┐ │
    │ ACTIVE │◄───────►│ INACTIVE │         │ DELETED│ │
    └────────┘         └──────────┘         └────────┘ │
         │                  │                    ▲      │
         │                  │                    │      │
         └──────────────────┘                    │      │
                      │                          │      │
                      └───► DELETED (soft-delete)┘      │
                                                     (terminal)
```

## Valid Transitions
| From | To | Method | Allowed? |
|------|----|--------|----------|
| active | inactive | `update_entity_status_with_outbox()` | ✅ Yes |
| inactive | active | `update_entity_status_with_outbox()` | ✅ Yes |
| active | deleted | `soft_delete_entity_with_outbox()` (DELETE endpoint) | ✅ Yes |
| inactive | deleted | `soft_delete_entity_with_outbox()` (DELETE endpoint) | ✅ Yes |
| deleted | active | `restore_entity_with_outbox()` (POST .../restore) | ✅ Yes (only way) |
| deleted | active | `update_entity_status_with_outbox()` (regular update) | ❌ No → `ErrInvalidStatusTransition` |
| deleted | inactive | Any method | ❌ No → `ErrInvalidStatusTransition` |
| any | invalid enum | Any method | ❌ No → PG ENUM rejects |

## Gherkin Scenario Coverage

### SCENARIO 1: active → inactive
- **Given**: Entity exists with status "active"
- **When**: User updates entity setting status="inactive"
- **Then**: Transition succeeds
- **And**: `entitymanagement.entity.updated` event emitted with `changed_fields` including "status"
- **Implementation**: `update_entity_status_with_outbox(entity_id, version, 'inactive'::entity_status)`

### SCENARIO 2: inactive → active
- **Given**: Entity exists with status "inactive"
- **When**: User updates entity setting status="active"
- **Then**: Transition succeeds
- **Implementation**: `update_entity_status_with_outbox(entity_id, version, 'active'::entity_status)`

### SCENARIO 3: active → deleted (soft-delete)
- **Given**: Entity exists with status "active"
- **When**: Soft-delete performed via DELETE endpoint
- **Then**: Entity status transitions to "deleted" (terminal state)
- **Implementation**: `soft_delete_entity_with_outbox(entity_id)` (from ENTITYMGMT-05)

### SCENARIO 4: deleted → active via update — REJECTED
- **Given**: Entity exists with status "deleted" (after soft-delete)
- **When**: User attempts status-only update setting status="active"
- **Then**: `ErrInvalidStatusTransition` returned
- **And**: Only way to exit "deleted" is via restore endpoint
- **Implementation**: `update_entity_status_with_outbox()` returns `INVALID_STATUS_TRANSITION`
- **No data modified, no event emitted**

### SCENARIO 5: invalid status value — REJECTED
- **Given**: Entity exists with status "inactive"
- **When**: User attempts to set status to invalid value "unknown"
- **Then**: `ErrInvalidStatusTransition` returned (caught by PG `entity_status` ENUM)
- **And**: No data is modified

## Database Artifacts

### Migration: `ENTITYMGMT-08_000_status_lifecycle.up.sql`
| Object | Type | Purpose |
|--------|------|---------|
| `validate_status_transition()` | FUNCTION | Core lifecycle validation (active↔inactive→deleted terminal) |
| `prevent_immutable_field_update()` | TRIGGER FUNCTION | Updated to allow active↔inactive (previously blocked all status changes) |
| `enqueue_entity_updated_event()` | FUNCTION | Updated payload with `previous_status` and `new_status` fields |
| `update_entity_optimistic()` | FUNCTION | Now returns `previous_status` and `new_status` columns |
| `update_entity_with_outbox()` | FUNCTION | Passes status transition info to enhanced outbox event |
| `update_entity_status_with_outbox()` | FUNCTION | **New** — Dedicated function for status-only updates |
| `verify_status_lifecycle()` | FUNCTION | **New** — Validates all lifecycle rules programmatically |

### Indexes
| Index | Type | Purpose |
|-------|------|---------|
| `idx_entities_status_transition` | B-tree (status, updated_at) | Find entities by current status |
| `idx_entities_schema_status_version` | B-tree (schema_id, status, version) | Optimistic update with status change |
| `idx_entities_status_updated` | B-tree (status, updated_at DESC) | Recent status transitions |
| `idx_entities_active_only` | Partial B-tree (WHERE status='active') | Active-only queries |
| `idx_entities_inactive_only` | Partial B-tree (WHERE status='inactive') | Inactive-only queries |

### Seed: `ENTITYMGMT-08_000_status_lifecycle_seed.sql`
- Creates 3 test entities: Alice (active), Bob (inactive), Charlie (deleted)
- Executes all 5 Gherkin scenarios with assertions
- Verifies outbox event payloads include `previous_status`/`new_status`
- Runs `verify_status_lifecycle()` diagnostic

### Queries: `ENTITYMGMT-08_status_transitions.sql`
Documents 8 query patterns for status lifecycle operations.

## Enhanced Event Payload

The `entitymanagement.entity.updated` event now includes:

```json
{
  "event_id": "<uuid>",
  "entity_id": "<uuid>",
  "entity_name": "Alice",
  "status": "inactive",
  "region": "eu-west-1",
  "previous_version": 3,
  "new_version": 4,
  "previous_status": "active",
  "new_status": "inactive",
  "changed_fields": ["status", "version"],
  "previous_state": {...},
  "new_state": {...},
  "occurred_at": "<timestamp>"
}
```

### Consumers
- **WorkflowEngine** — Trigger workflows on status transitions
- **AuditLog** — Record status change audit trail
- **NotificationService** — Notify subscribers of status changes

## Redis Caching
See `config/redis/entitymgmt-08_status_lifecycle.conf` for cache invalidation strategy on status transitions.

## Backward Compatibility
- All existing ENTITYMGMT-04/05/07 functions remain compatible
- `enqueue_entity_updated_event()` signature changed (added `p_previous_status` parameter) — callers updated
- `update_entity_optimistic()` return type extended with `previous_status`/`new_status` columns
- `prevent_immutable_field_update` trigger now additionally allows `active↔inactive` transitions

## Rollback
`ENTITYMGMT-08_000_status_lifecycle.down.sql` restores all functions and trigger to their pre-ENTITYMGMT-08 state.
After rollback, `active↔inactive` transitions will be blocked again (as they were before this migration).
