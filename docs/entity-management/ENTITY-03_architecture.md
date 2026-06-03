# Entity Management — Read Entity Instance by ID (ENTITY-03)

## Overview

This document describes the database schema additions, seed data, queries, and
caching strategy for story **ENTITY-03: Read Entity Instance by ID**.

This story extends the ENTITY-02 schema (entities table) with:
1. An audit log for entity read operations
2. Three new domain events for read outcomes
3. A combined "log + get" atomic function
4. Performance-optimized query functions
5. Redis caching configuration

## Gherkin Scenario Mapping

### SCENARIO 1: Retrieve an active entity

| Gherkin Step | Database Implementation |
|---|---|
| `existing entity with ID "ENT-456"` | `entities.id = 'ENT-456'` with `status = 'active'` |
| `GET /entities/ENT-456` | `SELECT * FROM get_entity_by_id('ENT-456')` |
| `full entity payload, schema ID, region, version, and timestamps` | Returns all columns from `get_entity_by_id()` including `schema_id`, `schema_version`, `region`, `created_at`, `updated_at` |
| `entity.EntityRetrieved` fired | `enqueue_entity_retrieved_event()` inserts into `event_outbox` |

### SCENARIO 2: Retrieve a soft-deleted entity

| Gherkin Step | Database Implementation |
|---|---|
| `soft-deleted entity with ID "ENT-789"` | `entities.id = 'ENT-789'` with `status = 'deleted'` AND `deleted_at IS NOT NULL` |
| `GET /entities/ENT-789` | `SELECT * FROM get_entity_by_id('ENT-789')` — returns entity regardless of status |
| `entity with a "deleted_at" timestamp field` | `get_entity_by_id()` returns `deleted_at` column (populated) |
| `entity.DeletedEntityRetrieved` fired | `enqueue_deleted_entity_retrieved_event()` inserts into `event_outbox` |

### SCENARIO 3: Retrieve a non-existent entity

| Gherkin Step | Database Implementation |
|---|---|
| `non-existent entity ID "ENT-999"` | No row with `id = 'ENT-999'` in `entities` |
| `GET /entities/ENT-999` | `SELECT * FROM get_entity_by_id('ENT-999')` → 0 rows |
| `response is 404 Not Found` | Application layer checks `FOUND` / `ROW_COUNT` from query and returns HTTP 404 |
| `entity.EntityRetrievalFailed` fired | `enqueue_entity_retrieval_failed_event('ENT-999')` inserts into `event_outbox` |

## Migration Files

### Core Migration

| # | File | Description |
|---|---|---|
| 1 | `docs/generated-app/default/database/migrations/ENTITY-03_000_read_entity_audit.up.sql` | ENTITY-03: entity_read_audit_log table, 6 query functions, 3 outbox event functions |
| 2 | `docs/generated-app/default/database/migrations/ENTITY-03_000_read_entity_audit.down.sql` | Reverts ENTITY-03 migration |

### Helper Files

| File | Description |
|---|---|
| `docs/generated-app/default/database/queries/ENTITY-03_get_entity_by_id.sql` | Primary query wrapper — get entity by ID |
| `docs/generated-app/default/database/queries/ENTITY-03_get_entity_with_schema_info.sql` | Extended query — entity + schema name/slug |
| `docs/generated-app/default/database/queries/ENTITY-03_log_and_get_entity.sql` | Atomic query — log read + return entity |
| `docs/generated-app/default/database/seeds/ENTITY-03_000_read_entity_audit_seed.sql` | Seed data for all 3 Gherkin scenarios |
| `docs/generated-app/default/database/redis/ENTITY-03_cache.conf` | Redis caching configuration |

## New Tables

### `entity_read_audit_log`

Immutable, append-only audit trail for all entity read operations.

| Column | Type | Description |
|---|---|---|
| `id` | UUID (PK) | Auto-generated unique identifier |
| `entity_id` | VARCHAR(64) | The entity that was read (NULL for not_found) |
| `request_id` | VARCHAR(255) | Request/trace ID for correlation |
| `outcome` | VARCHAR(32) | `'retrieved'` or `'not_found'` |
| `is_deleted` | BOOLEAN | Whether entity was soft-deleted at read time |
| `read_by` | VARCHAR(255) | Principal who performed the read |
| `entity_status` | entity_status | Snapshot of entity status at read time |
| `schema_id` | UUID | Schema reference for aggregation |
| `region` | VARCHAR(64) | Entity region for geographic observability |
| `read_at` | TIMESTAMPTZ | When the read occurred |
| `duration_ms` | INTEGER | Read latency in milliseconds |

**Indexes:** 6 partial/composite indexes optimized for observability queries including entity-scoped reads, 404 tracking, deleted entity retrievals, region-based queries, and time-range analysis.

**Retention:** 90 days (configurable via `prune_expired_read_audit_logs(90)`).

## Database Functions

New functions added in this migration:

| Function | Purpose |
|---|---|
| `log_entity_read(...)` | Records a read audit trail entry |
| `enqueue_entity_retrieved_event(...)` | Enqueues EntityRetrieved event (SCENARIO 1) |
| `enqueue_deleted_entity_retrieved_event(...)` | Enqueues DeletedEntityRetrieved event (SCENARIO 2) |
| `enqueue_entity_retrieval_failed_event(...)` | Enqueues EntityRetrievalFailed event (SCENARIO 3) |
| `get_entity_by_id(entity_id)` | Returns full entity row (all statuses included) |
| `get_entity_with_schema_info(entity_id)` | Returns entity + schema name/slug |
| `log_and_get_entity(...)` | **Atomic**: logs read + returns entity in one call |
| `get_read_audit_trail(entity_id, limit, offset)` | Paginated read audit trail for an entity |
| `prune_expired_read_audit_logs(days)` | TTL-based cleanup of audit logs (default 90 days) |

## Domain Events

Three new domain events are emitted via the transactional outbox pattern
(per ADR-002):

| Event (CloudEvents Type) | When Fired | Scenario |
|---|---|---|
| `entitymanagement.EntityRetrieved` | GET /entities/{id} returns a non-deleted entity | SCENARIO 1 |
| `entitymanagement.DeletedEntityRetrieved` | GET /entities/{id} returns a soft-deleted entity | SCENARIO 2 |
| `entitymanagement.EntityRetrievalFailed` | GET /entities/{id} returns 404 Not Found | SCENARIO 3 |

### Event: `entitymanagement.EntityRetrieved`

```json
{
  "entityId": "ENT-456",
  "entityName": "billing-service",
  "entityType": "ServiceComponent",
  "region": "us-east-1",
  "schemaVersion": 1,
  "status": "active",
  "readBy": "u0000000-...",
  "readAt": "2026-06-03T14:32:00Z"
}
```

### Event: `entitymanagement.DeletedEntityRetrieved`

```json
{
  "entityId": "ENT-789",
  "entityName": "retired-cache-node",
  "entityType": "ServiceComponent",
  "region": "eu-west-1",
  "deletedAt": "2026-05-27T14:32:00Z",
  "readBy": "u0000000-...",
  "readAt": "2026-06-03T14:32:00Z"
}
```

### Event: `entitymanagement.EntityRetrievalFailed`

```json
{
  "entityId": "ENT-999",
  "reason": "not_found",
  "readBy": "u0000000-...",
  "readAt": "2026-06-03T14:32:00Z"
}
```

## Data Flow: GET /entities/{id}

```
Client → HTTP Handler → Application Use Case → Database
                                                    │
                         ┌──────────────────────────┘
                         ▼
              log_and_get_entity(id, request_id, read_by)
                         │
                         ├── 1. SELECT entity FROM entities WHERE id = ?
                         │
                         ├── 2. Determine outcome (found? deleted?)
                         │
                         ├── 3. INSERT INTO entity_read_audit_log (...)
                         │
                         └── 4. RETURN (found, is_deleted, entity_json, audit_id)
                              │
                              ▼
                    ┌── found=TRUE, is_deleted=FALSE ──→ HTTP 200 (full payload)
                    │                                   enqueue_entity_retrieved_event()
                    │
                    ├── found=TRUE, is_deleted=TRUE ────→ HTTP 200 (with deleted_at)
                    │                                   enqueue_deleted_entity_retrieved_event()
                    │
                    └── found=FALSE ────────────────────→ HTTP 404
                                                        enqueue_entity_retrieval_failed_event()
```

## Caching Strategy (Redis)

Configuration: `docs/generated-app/default/database/redis/ENTITY-03_cache.conf`

| Cache Key Pattern | TTL | Purpose |
|---|---|---|
| `entity:{id}` | 5 min | Full entity object cache (cache-aside) |
| `entity:not_found:{id}` | 30 sec | Negative cache for 404 optimization |
| `entity:read_audit:{id}:{limit}:{offset}` | 60 sec | Read audit trail cache |

Cache invalidation is triggered by:
- `entity.EntityUpdated` → `DEL entity:{id}`
- `entity.EntityDeleted` → `DEL entity:{id}`
- `entity.EntityCreated` → `DEL entity:not_found:{id}`

## Seed Data

File: `docs/generated-app/default/database/seeds/ENTITY-03_000_read_entity_audit_seed.sql`

| Seed | Entity ID | Status | Scenario |
|---|---|---|---|
| billing-service | ENT-456 | active | SCENARIO 1: Retrieve active entity |
| retired-cache-node | ENT-789 | deleted (soft) | SCENARIO 2: Retrieve soft-deleted entity |
| (none) | ENT-999 | N/A (does not exist) | SCENARIO 3: 404 Not Found |

The seed also pre-populates:
- 2 read audit log entries (1 for ENT-456, 1 for ENT-789)
- 3 event_outbox entries (EntityRetrieved, DeletedEntityRetrieved, EntityRetrievalFailed)
