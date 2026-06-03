# ENTITY-05: Soft-Delete, Hard-Delete, and Restore Entity Instances

## Domain Model

This story adds the **data lifecycle** layer to the entity management bounded context. Entities follow a three-stage lifecycle:

```
Created → Active → Soft-Deleted → (Hard-Deleted | Restored)
```

### Lifecycle State Machine

```
                    ┌──────────────────────────────────────┐
                    │                                      │
                    v                                      │
 ┌──────────┐   ┌──────────┐   ┌──────────────┐   ┌───────────────┐
 │ Created  │──▶│  Active  │──▶│ Soft-Deleted │──▶│ Hard-Deleted  │
 │ (status  │   │ (status  │   │ (deleted_at  │   │ (permanently  │
 │ = active │   │ = active │   │  is set,     │   │  removed from │
 │ , no     │   │ )        │   │  status      │   │  database)    │
 │ deleted  │   │          │   │  = deleted)  │   │               │
 │ _at)     │   │          │   │              │   └───────────────┘
 └──────────┘   └──────────┘   └──────┬───────┘
                                       │
                                       │ Restore (POST /entities/{id}/restore)
                                       │
                                       v
                               ┌──────────────┐
                               │   Restored   │
                               │ (deleted_at  │
                               │  = NULL,     │
                               │  status      │
                               │  = active)   │
                               └──────────────┘
```

### Three Operations (One migration)

| Operation | HTTP Method | Flag | DB Effect | Event Emitted |
|-----------|------------|------|-----------|---------------|
| **Soft-Delete** | `DELETE /entities/{id}` | Default | `deleted_at = NOW()`, `status = 'deleted'`, `version++` | `entitymanagement.EntitySoftDeleted` |
| **Hard-Delete** | `DELETE /entities/{id}` | `?permanent=true` | `DELETE FROM entities` (only if already soft-deleted) | `entitymanagement.EntityHardDeleted` |
| **Restore** | `POST /entities/{id}/restore` | N/A | `deleted_at = NULL`, `status = 'active'`, `version++` | `entitymanagement.EntityRestored` |

### Core Tables (No new tables — all additive functions)

| Object | Type | Purpose |
|--------|------|---------|
| `soft_delete_entity()` | Function | Atomic soft-delete (sets deleted_at, status, bumps version) |
| `hard_delete_entity()` | Function | Atomic hard-delete (permanent DELETE, validates soft-deleted first) |
| `restore_entity()` | Function | Atomic restore (clears deleted_at, reverts status to active) |
| `delete_entity_with_restore_check()` | Function | Top-level dispatcher (decides soft vs hard based on state + ?permanent flag) |
| `enqueue_entity_soft_deleted_event()` | Function | Writes `entitymanagement.EntitySoftDeleted` to `event_outbox` |
| `enqueue_entity_hard_deleted_event()` | Function | Writes `entitymanagement.EntityHardDeleted` to `event_outbox` |
| `enqueue_entity_restored_event()` | Function | Writes `entitymanagement.EntityRestored` to `event_outbox` |
| `soft_delete_entity_with_outbox()` | Function | Combined: soft-delete + enqueue event (atomic) |
| `hard_delete_entity_with_outbox()` | Function | Combined: hard-delete + enqueue event (atomic) |
| `restore_entity_with_outbox()` | Function | Combined: restore + enqueue event (atomic) |
| `active_entities` | View | Default list query — **automatically excludes** soft-deleted entities |
| `list_entities_active()` | Function | Paginated listing of non-deleted entities only |
| `list_entities_with_deleted()` | Function | Admin listing that optionally includes deleted entities |
| `get_soft_deleted_entities()` | Function | "Recycle bin" — lists all currently soft-deleted entities |
| `count_entities_by_deleted_status()` | Function | Returns count grouped by `active` vs `soft_deleted` |
| `purge_soft_deleted_entities_older_than()` | Function | Data lifecycle — permanently removes entities deleted > N days ago |
| `row_to_entity_json()` | Helper | Converts entity row to JSONB (shared by all three operations) |

### Key Design Decisions

1. **No new tables** — The `entities` table already has `deleted_at TIMESTAMPTZ` (from ENTITY-02) and the `entity_status` ENUM already contains `'deleted'` (from ENTITY-02). This migration is entirely additive: functions, views, and indexes.

2. **Atomic operations with row-level locking** — All three mutation functions (`soft_delete_entity`, `hard_delete_entity`, `restore_entity`) use `SELECT ... FOR UPDATE` to prevent race conditions. The version column is incremented for OCC consistency with the existing update flow.

3. **Transactional outbox** — Each operation has a `*_with_outbox()` variant that combines the data mutation and event emission in a single database transaction. The top-level `delete_entity_with_restore_check()` dispatches to the correct inner function.

4. **Validation gates**:
   - Soft-delete rejects: entity not found, already soft-deleted, invalid status transition
   - Hard-delete rejects: entity not found, not soft-deleted (active entities must be soft-deleted first)
   - Restore rejects: entity not found, not soft-deleted (active entities cannot be restored)

5. **Default exclusion from list queries** — The `active_entities` view and `list_entities_active()` function automatically filter out soft-deleted entities. Platform engineers must explicitly use `list_entities_with_deleted()` or `get_soft_deleted_entities()` to see deleted data.

6. **Data lifecycle** — `purge_soft_deleted_entities_older_than()` implements the data retention policy. Default is 30 days, configurable per region.

### Event Types

| Event | Outbox Type | Payload Highlights |
|-------|-------------|-------------------|
| `EntitySoftDeleted` | `entitymanagement.EntitySoftDeleted` | entityId, entityName, region, deletedBy, previousStatus, deletedAt |
| `EntityHardDeleted` | `entitymanagement.EntityHardDeleted` | entityId, entityName, region, deletedBy, deletedAt |
| `EntityRestored` | `entitymanagement.EntityRestored` | entityId, entityName, region, restoredBy, occurredAt |

### Savoring Domain Events (from domain/types.go)

```go
type EntitySoftDeleted struct {
    EventID    string    `json:"event_id"`
    EntityID   string    `json:"entity_id"`
    EntityName string    `json:"entity_name"`
    Region     string    `json:"region"`
    DeletedAt  time.Time `json:"deleted_at"`
    OccurredAt time.Time `json:"occurred_at"`
}

type EntityHardDeleted struct {
    EventID    string    `json:"event_id"`
    EntityID   string    `json:"entity_id"`
    EntityName string    `json:"entity_name"`
    Region     string    `json:"region"`
    DeletedAt  time.Time `json:"deleted_at"`
    OccurredAt time.Time `json:"occurred_at"`
}

type EntityRestored struct {
    EventID    string    `json:"event_id"`
    EntityID   string    `json:"entity_id"`
    EntityName string    `json:"entity_name"`
    Region     string    `json:"region"`
    OccurredAt time.Time `json:"occurred_at"`
}
```

### Indexes Added

| Index | Type | Purpose |
|-------|------|---------|
| `idx_entities_deleted_at` | Partial B-tree, `deleted_at DESC` | "List soft-deleted entities" query |
| `idx_entities_deleted_at_retention` | Partial B-tree, `deleted_at ASC` | "Purge old deletions" query |
| `idx_entities_schema_deleted` | Composite partial, `(schema_id, deleted_at)` | "Soft-deleted entities by type" |
| `idx_entities_region_deleted` | Composite partial, `(region, deleted_at)` | "Soft-deleted entities by region" |
| `idx_entities_deleted_at_recent` | Partial B-tree | "Recently deleted" (last 7 days) |
| `idx_entities_restorable` | Composite partial, `(id, deleted_at)` | "Can this entity be restored?" |
| `idx_event_outbox_lifecycle_events` | Partial B-tree | Fast filtering of lifecycle events |

### Migration Order

1. `ENTITY-02_000_create_entity_instances.up.sql` — Entities table (prerequisite)
2. `ENTITY-04_000_optimistic_concurrency.up.sql` — Version column (prerequisite)
3. **`ENTITY-05_000_soft_delete_restore.up.sql`** — This migration (additive)
4. `ENTITY-05_000_soft_delete_restore_seed.sql` — Seed data

### Redis Cache

Configuration at `docs/generated-app/default/database/redis/ENTITY-05_soft_delete_cache.conf`.

Key invalidation patterns:
- `entity:{id}` — Cleared on soft-delete, refreshed on restore
- `entity:{id}:version` — Cleared on soft-delete
- `entity:{id}:deleted_at` — Set on soft-delete, cleared on restore/hard-delete
- `entity:list:active` — Cleared on any lifecycle operation (stale list)
- `entity:trash` — Populated on soft-delete, cleared on restore/hard-delete
