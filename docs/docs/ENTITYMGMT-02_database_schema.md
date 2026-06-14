

# ENTITYMGMT-02: Entity Creation with Idempotency

## Overview

Story: User creates an entity with idempotency support (7-day TTL)

This migration adds the `entities` and `request_idempotency` tables and all supporting functions to the Entity Management bounded context. It reuses the `outbox_events` table from ENTITYMGMT-01 for the transactional outbox pattern.

## Tables

### `entities`
Concrete entity instances conforming to an `entity_schema` blueprint.

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID PK | Unique entity identifier (gen_random_uuid()) |
| `schema_id` | UUID FK | Reference to entity_schemas.id |
| `schema_version` | INTEGER | Version of the schema at creation time |
| `name` | VARCHAR(512) | Entity name (unique per schema) |
| `type` | VARCHAR(255) | Entity type (denormalized from schema name) |
| `region` | VARCHAR(64) | Cloud provider region |
| `data_residency_zone` | TEXT (generated) | Auto-computed from region via `compute_data_residency_zone()` |
| `status` | entity_status ENUM | 'active' (default), 'inactive', 'deleted', 'provisioning' |
| `version` | INTEGER | Optimistic concurrency version (starts at 1) |
| `attributes` | JSONB | Dynamic schema-defined attributes |
| `metadata` | JSONB | Free-form metadata |
| `created_at` | TIMESTAMPTZ | Creation timestamp |
| `updated_at` | TIMESTAMPTZ | Last update timestamp (auto-updated by trigger) |
| `deleted_at` | TIMESTAMPTZ | Soft-delete timestamp |

**Constraints:**
- `uq_entities_schema_name`: UNIQUE(schema_id, name) — no duplicate names per schema
- `fk_entities_schema`: FK to entity_schemas.id with RESTRICT on delete

### `request_idempotency`
Client-supplied idempotency key → entity ID mapping with 7-day TTL.

| Column | Type | Description |
|--------|------|-------------|
| `request_key` | TEXT PK | Client-supplied idempotency key (e.g., "create-customer-001") |
| `entity_id` | UUID FK | Entity that was created for this key |
| `expires_at` | TIMESTAMPTZ | TTL expiry (created_at + 7 days) |
| `created_at` | TIMESTAMPTZ | Record creation timestamp |

**Constraints:**
- `fk_request_idempotency_entity`: FK to entities.id with CASCADE on delete
- `ck_request_idempotency_expires_at_check`: TTL between 1 hour and 30 days

## Gherkin Scenario Mapping

### SCENARIO 1: Successful creation
```
Given schema "Customer" exists
When POST /api/v1/entities with Idempotency-Key: "create-customer-001"
Then entity created with status="active", version=1
  And tagged with DataResidencyZone="eu-west-1"
  And entitymanagement.entity.created event enqueued in outbox
  And idempotency key stored with 7-day TTL
  And HTTP 201 returned
```

**Flow:**
1. App calls `get_entity_by_idempotency_key('create-customer-001')` → no rows
2. App calls `create_entity_with_idempotency(...)` within a DB transaction:
   - Inserts into `entities` with status='active', version=1
   - `data_residency_zone` generated column computes 'eu' from 'eu-west-1'
   - Inserts into `outbox_events` with event_type='entitymanagement.entity.created'
   - Inserts into `request_idempotency` with expires_at = NOW() + 7 days
3. Returns entity ID + version (HTTP 201)

### SCENARIO 2: Idempotent replay
```
Given idempotency key "create-customer-001" was used before
When POST /api/v1/entities with same key
Then existing entity returned (HTTP 200)
  And no duplicate entity created
  And no duplicate entity.created event emitted
```

**Flow:**
1. App calls `get_entity_by_idempotency_key('create-customer-001')` → returns entity
2. App returns entity directly (HTTP 200), skips UnitOfWork entirely
3. No database writes occur

### SCENARIO 3: Expired key
```
Given idempotency key "expired-key" stored 8 days ago
When POST /api/v1/entities with that key
Then key treated as expired (TTL exceeded)
  And new entity created
```

**Flow:**
1. App calls `get_entity_by_idempotency_key('expired-key')` → no rows (expires_at < NOW())
2. App proceeds as new creation (same as SCENARIO 1)
3. `prune_expired_idempotency()` removes expired rows (run by scheduler)

## Event Payload

The `entitymanagement.entity.created` event is enqueued in `outbox_events` with:

```json
{
  "event_id": "uuid-v4",
  "entity_id": "uuid-v4",
  "entity_name": "Alice",
  "entity_type": "customer",
  "region": "eu-west-1",
  "data_residency_zone": "eu",
  "schema_id": "uuid-v4",
  "version": 1,
  "status": "active",
  "attributes": {"email": "alice@example.com", "name": "Alice"},
  "metadata": {},
  "occurred_at": "2026-01-15T10:30:00Z"
}
```

**Consumers:** Billing, Search, Notification, Audit, OutboxRelay (publish to NATS)

## Functions

| Function | Purpose |
|----------|---------|
| `compute_data_residency_zone(region)` | Maps cloud region to residency zone (IMMUTABLE, used by generated column) |
| `enqueue_entity_created_event(...)` | Inserts entitymanagement.entity.created event into outbox_events |
| `save_idempotency_key(key, entity_id, ttl_days)` | Records idempotency key → entity mapping with TTL |
| `get_entity_by_idempotency_key(key)` | Retrieves entity by idempotency key (returns NULL if expired/not found) |
| `create_entity_with_idempotency(...)` | Atomic: check idempotency → insert entity → enqueue event → save key |
| `prune_expired_idempotency()` | Removes expired idempotency records (for scheduler) |
| `get_entity_by_id(id, include_deleted)` | Retrieves entity by primary ID |
| `list_entities_by_schema(schema_id, status, limit, offset, include_deleted)` | Paginated entity listing |
| `count_entities_by_schema(schema_id, status, include_deleted)` | Entity count per schema |

## Index Strategy

- **schema_id + status**: Most common filtered listing
- **schema_id + status + created_at DESC**: Paginated listing
- **data_residency_zone**: Region-scoped queries
- **attributes/metadata (GIN)**: JSONB querying for dynamic attributes
- **request_idempotency.expires_at**: TTL-based cleanup
- **request_idempotency.active (partial)**: Fast lookup for non-expired keys

## Redis Cache Integration

New cache entries (added to `config/redis/cache.conf`):

| Key Pattern | TTL | Purpose |
|------------|-----|---------|
| `entity:{entity_id}` | 5 min | Entity read cache |
| `idempotency:req:{request_key}` | 7 days | Idempotent replay fast path |
| `entities:schema:{id}:status:{s}:page:{token}` | 1 min | Entity list cache |
| `residency:zone:{region}` | 1 day | Region-to-zone mapping (immutable) |
| `entities:count:{schema_id}:{status}` | 1 min | Entity count dashboard |
