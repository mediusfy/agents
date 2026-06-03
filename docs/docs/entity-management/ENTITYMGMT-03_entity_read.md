

# ENTITYMGMT-03: User Retrieves an Entity by ID with Observability Event

## Story

**As a** platform engineer  
**I want to** retrieve a specific entity by its unique ID  
**So that** I can view its full details and trigger observability tracking

## Gherkin Scenarios

### SCENARIO 1: Successful entity retrieval with observability event

```
Given an entity with ID "ent-abc-123" exists
When a GET /api/v1/entities/ent-abc-123 request is made
Then the full entity payload is returned (HTTP 200)
  Including all attributes, schema_id, region, status, version, created_at, updated_at
  And an entitymanagement.entity.read domain event is published (fire-and-forget, non-blocking)
```

### SCENARIO 2: Non-existent entity returns 404 without event

```
Given an entity with ID "ent-nonexistent" does not exist
When a GET /api/v1/entities/ent-nonexistent request is made
Then HTTP 404 is returned with ErrorResponse {code: "NOT_FOUND", message: "entity not found"}
  And no entity.read event is published
```

## Domain Events

### entitymanagement.entity.read

| Attribute     | Description                                     |
|---------------|-------------------------------------------------|
| **Owned by**  | EntityManagement context                        |
| **Delivery**  | Fire-and-forget, non-blocking                   |
| **Published** | Only on successful retrieval (not on 404)       |
| **Payload**   | `{event_id, entity_id, entity_name, region, read_at, request_origin}` |

**Consumers:**
- **ObservabilityContext** — Read latency metrics (p50/p95/p99), access audit trail
- **ResidencyContext** — Cross-region read tracking (which origins read entities in which regions)

## Database Schema

### New Table: `entity_read_audit_log`

Immutable append-only audit trail for entity read operations.

| Column           | Type           | Description                                      |
|------------------|----------------|--------------------------------------------------|
| `id`             | UUID           | Primary key (auto-generated)                     |
| `entity_id`      | VARCHAR(64)    | The entity that was read (NULL for not_found)    |
| `request_id`     | VARCHAR(255)   | Request/trace ID for correlation                 |
| `outcome`        | VARCHAR(32)    | `'retrieved'` or `'not_found'`                   |
| `is_deleted`     | BOOLEAN        | Whether the entity was soft-deleted              |
| `read_by`        | VARCHAR(255)   | Authenticated user/principal                     |
| `request_origin` | VARCHAR(128)   | Source of the read request (e.g., 'api-gateway') |
| `entity_status`  | entity_status  | Snapshot of entity status at read time           |
| `schema_id`      | UUID           | Schema reference for aggregation queries         |
| `region`         | VARCHAR(64)    | Entity region for geographic observability       |
| `read_at`        | TIMESTAMPTZ    | When the read occurred                           |
| `duration_ms`    | INTEGER        | Read latency in milliseconds                     |

### New Functions

| Function                                      | Purpose                                                    |
|-----------------------------------------------|------------------------------------------------------------|
| `log_entity_read(...)`                        | Records a read event to the audit log                      |
| `enqueue_entity_read_event(...)`              | Enqueues entitymanagement.entity.read event to outbox      |
| `get_entity_by_id_with_audit(...)`            | Atomic: retrieve entity + log audit + enqueue event        |
| `get_read_audit_trail(entity_id, ...)`        | Query read audit history for an entity                     |
| `get_read_audit_trail_by_origin(origin, ...)` | Query read audit filtered by request origin                |
| `get_read_latency_percentiles(...)`           | Returns p50/p95/p99 latency by schema/region/outcome       |
| `get_cross_region_read_summary(...)`          | Cross-region read activity summary (for ResidencyContext)  |
| `prune_expired_read_audit_logs(...)`          | TTL-based cleanup (default 90-day retention)               |

## Redis Caching

Configuration: `docs/config/redis-entity-read.conf`

Key naming:
- `entity:{entity_id}` — Full entity payload (TTL: 5 min)
- `entity:version:{entity_id}` — Current version for stale detection (no expiry)
- `entity:lock:{entity_id}` — Distributed lock for read-repair (TTL: 3s)

## Files

| File | Purpose |
|------|---------|
| `database/migrations/ENTITYMGMT-03_000_read_entity_audit.up.sql` | Migration (up) |
| `database/migrations/ENTITYMGMT-03_000_read_entity_audit.down.sql` | Migration (down) |
| `database/seeds/ENTITYMGMT-03_000_read_entity_audit_seed.sql` | Seed data |
| `database/queries/ENTITYMGMT-03_get_entity_by_id.sql` | Named query for application layer |
| `docs/config/redis-entity-read.conf` | Redis caching configuration |
| `docs/entity-management/ENTITYMGMT-03_entity_read.md` | This document |

## Migration Dependency Order

```
ENTITYMGMT-01 (schema_definition)
  └── ENTITYMGMT-02 (create_entities)
        └── ENTITYMGMT-03 (read_entity_audit) ← YOU ARE HERE
```

The `get_entity_by_id()` function from ENTITYMGMT-02 is reused internally by `get_entity_by_id_with_audit()`.
The `outbox_events` table from ENTITYMGMT-01 is used for the entitymanagement.entity.read event.
