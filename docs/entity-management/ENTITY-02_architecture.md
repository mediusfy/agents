# Entity Management — Database & Caching Architecture

## Overview

This document describes the database schema, migrations, seed data, and caching
strategy for the **Entity Management** bounded context, focusing on story
**ENTITY-02: Create Entity Instance from a defined schema**.

## Migration Files

### Core Migrations (in order)

| # | File | Description |
|---|------|-------------|
| 1 | `docs/migrations/002_create_entity_schemas.sql` | ENTITY-01: Schema definitions, field types, validation rules, event_outbox |
| 2 | `docs/generated-app/default/database/migrations/ENTITY-02_000_create_entity_instances.up.sql` | ENTITY-02: Entity instances, request-level idempotency, EntityCreated outbox |

### Down Migrations

| File | Description |
|------|-------------|
| `docs/generated-app/default/database/migrations/ENTITY-02_000_create_entity_instances.down.sql` | Reverts ENTITY-02 migration |

## Tables

### `entities` (ENTITY-02)

The aggregate root for entity instances. Each entity conforms to exactly one
`entity_schema` blueprint. Canonical fields (`name`, `region`, `status`) are
first-class columns for indexing and querying; dynamic schema-defined attributes
live in the `attributes` JSONB column.

**Key columns:**
- `id` (UUID, PK) — Auto-generated unique entity identifier
- `schema_id` (UUID, FK → entity_schemas.id) — Schema blueprint reference
- `schema_version` (INTEGER) — Schema version at time of entity creation
- `name` (VARCHAR(512)) — Entity name (unique per schema ID)
- `type` (VARCHAR(255)) — Denormalized schema name for fast filtering
- `region` (VARCHAR(64)) — Cloud provider region
- `data_residency_zone` (TEXT, GENERATED) — Auto-computed from region
- `status` (entity_status enum) — Lifecycle: active, inactive, deleted, provisioning
- `attributes` (JSONB) — Dynamic schema-defined attributes
- `metadata` (JSONB) — Free-form metadata (tags, labels)

**Indexes:** 15 indexes covering schema lookups, region queries, status filters,
full-text search, JSONB path queries, and partial indexes for active entities.

### `request_idempotency` (ENTITY-02)

Client-supplied idempotency key → entity ID mapping with 7-day TTL.
Enables Gherkin SCENARIO 1 (first request creates) and SCENARIO 2 (duplicate
request returns existing).

**Key columns:**
- `request_key` (TEXT, PK) — Client-supplied idempotency string
- `entity_id` (UUID, FK → entities.id) — The created entity
- `expires_at` (TIMESTAMPTZ) — TTL expiry (auto-cleanup via `prune_expired_idempotency()`)

## Domain Events

### `entitymanagement.EntityCreated`

Published when a platform engineer successfully creates a new entity.

**CloudEvents Attributes:**
- Type: `entitymanagement.EntityCreated`
- Source: `entity-management`
- Subject: `entity/{entityId}`

**Payload:**
```json
{
  "entityId": "a1000001-...",
  "entityName": "api-gateway",
  "entityType": "ServiceComponent",
  "region": "us-east-1",
  "schemaVersion": 1,
  "createdBy": "u0000000-...",
  "createdAt": "2026-06-03T14:32:00Z"
}
```

**Delivery Guarantee:** At-least-once delivery via the transactional outbox
pattern. The entity insert and outbox event insert occur in the same database
transaction.

## Database Functions

| Function | Purpose |
|----------|---------|
| `compute_data_residency_zone(region)` | Maps region → data residency zone (generated column) |
| `enqueue_entity_created_event(...)` | Inserts EntityCreated event into event_outbox |
| `create_entity_with_outbox(...)` | Atomic entity creation + event emission |
| `save_idempotency_key(...)` | Upserts request_key → entity_id mapping |
| `get_entity_by_idempotency_key(key)` | Returns entity for idempotent replay |
| `get_schema_entity_count(schema_id, status)` | Entity count per schema |
| `prune_expired_idempotency()` | Cleans up expired idempotency records |

## Caching Strategy (Redis)

Configuration: `docs/generated-app/default/database/redis/ENTITY-02_cache.conf`

| Cache Key Pattern | TTL | Purpose |
|-------------------|-----|---------|
| `entity:{id}` | 5 min | Full entity object cache |
| `schema:{id}` | 15 min | Compiled schema validator cache |
| `idempotency:{request_key}` | 7 days | Idempotency key cache (mirrors DB) |
| `region:{region}:entity:{id}` | 5 min | Region-based entity index |

Cache invalidation is triggered by `entitymanagement.EntityCreated` and
`entity.EntityUpdated` events consumed via the outbox relay.

## Seed Data

File: `docs/generated-app/default/database/seeds/ENTITY-02_000_create_entity_instances_seed.sql`

Seeds the `ServiceComponent` schema with 5 fields (name, region, status, owner,
version) and 4 sample entities (api-gateway, user-service, analytics-pipeline,
old-cache-layer) with associated EntityCreated events and idempotency records.

## Gherkin Scenario Mapping

### SCENARIO 1: Successfully create an entity with idempotency

| Gherkin Step | Implementation |
|-------------|----------------|
| "existing schema with schema ID 'S-123'" | `entity_schemas.id = 'f0000001-...'` |
| "valid payload matching the schema fields" | Validated by `validateAgainstSchema()` in Go domain service |
| "create request with an idempotency key 'key-abc'" | `request_idempotency.request_key = 'key-abc'` |
| "entity is created with a unique entity ID" | `entities.id` (UUID, gen_random_uuid()) |
| "EntityCreated is emitted via the transactional outbox" | `event_outbox` insert with event_type='entitymanagement.EntityCreated' |
| "response includes the entity ID and created timestamp" | `create_entity_with_outbox()` returns (entity_id, created_at) |

### SCENARIO 2: Idempotent duplicate request

| Gherkin Step | Implementation |
|-------------|----------------|
| "duplicate create request with the same idempotency key" | `get_entity_by_idempotency_key('key-abc')` returns existing entity_id |
| "previously created entity is returned without creating a duplicate" | Go service returns existing entity, skips UnitOfWork |
| "no additional EntityCreated event is emitted" | INSERT into event_outbox is never executed |
