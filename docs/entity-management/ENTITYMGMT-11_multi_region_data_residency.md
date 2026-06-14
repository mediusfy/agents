# Entity Management — Multi-Region Data Residency (ENTITYMGMT-11)

## Overview

This document describes the database schema changes, seed data, queries, and
caching strategy for story **ENTITYMGMT-11: System enforces multi-region data
residency (us-east-1, eu-west-1)**.

This story updates the existing `compute_data_residency_zone()` function to
provide **one-to-one region-to-zone mapping** (eu-west-1 → eu-west-1, not 'eu'),
introduces a new `entitymanagement.residency.region_routed` domain event for
observability span enrichment, and enforces immutability of the
`data_residency_zone` field.

## Key Change: Zone Mapping Strategy

| Aspect | Before (ENTITYMGMT-02) | After (ENTITYMGMT-11) |
|--------|----------------------|----------------------|
| eu-west-1 → | `'eu'` (grouped) | `'eu-west-1'` (one-to-one) |
| us-east-1 → | `'us'` (grouped) | `'us-east-1'` (one-to-one) |
| Unknown regions → | `'other'` | Pass through as-is |
| IMMUTABLE function | Yes | Yes |
| Generated column | `GENERATED ALWAYS AS ... STORED` | Same (recreated) |

## Gherkin Scenario Mapping

### SCENARIO 1: Entity creation resolves correct DataResidencyZone

| Gherkin Step | Database Implementation |
|---|---|
| `system is deployed across us-east-1 and eu-west-1 regions` | `entities.region` column stores the source region |
| `entity created with region="eu-west-1"` | `INSERT INTO entities (region) VALUES ('eu-west-1')` |
| `DataResidencyZone is resolved to "eu-west-1"` | `compute_data_residency_zone('eu-west-1')` returns `'eu-west-1'` via generated column |
| `observability spans include region attribute` | `enqueue_region_routed_event()` emits `entitymanagement.residency.region_routed` |

### SCENARIO 2: Known region mapping

| Gherkin Step | Database Implementation |
|---|---|
| `region "eu-west-1" maps to zone "eu-west-1"` | `compute_data_residency_zone('eu-west-1')` = `'eu-west-1'` |
| `region "us-east-1" maps to zone "us-east-1"` | `compute_data_residency_zone('us-east-1')` = `'us-east-1'` |
| `ResolveZone function called` | Domain `ResolveZone()` in Go matches SQL function |
| `unknown regions pass through as-is` | `compute_data_residency_zone('unknown')` = `'unknown'` |

### SCENARIO 3: Immutable data_residency_zone field

| Gherkin Step | Database Implementation |
|---|---|
| `entity's data_residency_zone is set to "eu-west-1"` | Generated column value from region |
| `user attempts to update data_residency_zone` | `prevent_immutable_field_update` trigger fires |
| `ErrImmutableField is returned` | PostgreSQL raises `ERR_IMMUTABLE_FIELD: data_residency_zone is a generated column...` |
| `no data modification occurs` | Transaction rolled back by trigger exception |

## Migration Files

### Core Migration

| # | File | Description |
|---|---|---|
| 1 | `entity-management/database/migrations/ENTITYMGMT-11_000_multi_region_data_residency.up.sql` | ENTITYMGMT-11: Update zone mapping, region_routed event, new indexes |
| 2 | `entity-management/database/migrations/ENTITYMGMT-11_000_multi_region_data_residency.down.sql` | Reverts ENTITYMGMT-11 migration |

### Helper Files

| File | Description |
|---|---|
| `entity-management/database/queries/ENTITYMGMT-11_resolve_zone.sql` | Zone resolution queries for app layer |
| `entity-management/database/seeds/ENTITYMGMT-11_000_multi_region_data_residency_seed.sql` | Seed data for all 3 Gherkin scenarios |
| `config/redis_residency.conf` | Redis caching configuration for residency data |

## Tables

### `entities` — Updated columns

| Column | Type | Change |
|---|---|---|
| `data_residency_zone` | TEXT (GENERATED) | **Recreated**: now uses updated `compute_data_residency_zone()` |
| `region_updated_at` | TIMESTAMPTZ | **New**: tracks when region was last set (immutable after creation) |

### New Indexes

| Index Name | Columns | Purpose |
|---|---|---|
| `idx_entities_zone_region_status` | `(data_residency_zone, region, status)` | Zone-based filtering + status |
| `idx_entities_zone_created_at` | `(data_residency_zone, created_at DESC)` | Zone-based time-series |
| `idx_entities_region_zone_updated` | `(region, data_residency_zone, updated_at DESC)` | Routing table updates |
| `idx_entities_known_zones` | `(data_residency_zone, region)` WHERE known regions | Known zone filtering |
| `idx_entities_region_updated_at` | `(region_updated_at DESC)` | Observability tracking |
| `idx_entities_schema_zone` | `(schema_id, data_residency_zone)` | Schema + zone filtering |
| `idx_outbox_region_routed` | `(created_at DESC)` WHERE `event_type = 'entitymanagement.residency.region_routed'` | region_routed event lookup |

## Database Functions

### New Functions

| Function | Purpose |
|---|---|
| `compute_data_residency_zone(p_region TEXT)` | **Updated**: one-to-one mapping; unknown regions pass through |
| `enqueue_region_routed_event(...)` | Emits `entitymanagement.residency.region_routed` for observability |
| `resolve_entity_zone(p_entity_id UUID)` | Returns entity's zone + routing decision |
| `count_entities_by_zone()` | Returns entity counts grouped by zone |
| `list_entities_by_zone(zone, status, limit, offset)` | Lists entities in a specific zone |

### Updated Functions

| Function | What Changed |
|---|---|
| `enqueue_entity_created_event(...)` | Now also emits `region_routed` event inside the function |
| `create_entity_with_idempotency(...)` | Now initializes `region_updated_at` column |
| `prevent_immutable_field_update()` | Now also protects `region_updated_at` from independent modification |

## Domain Events

### New Event: `entitymanagement.residency.region_routed`

Published when an entity is routed to a specific data residency zone.

**CloudEvents Attributes:**
- Type: `entitymanagement.residency.region_routed`
- Source: `/entity-manager`
- Subject: `residency/region/{entity_id}`
- Owned by: EntityManagement context

**Payload per Gherkin spec:**
```json
{
  "event_id": "a1b2c3d4-...",
  "entity_id": "e1100001-...",
  "region": "eu-west-1",
  "data_residency_zone": "eu-west-1",
  "routing_decision": "direct_map",
  "occurred_at": "2026-06-15T14:32:00Z"
}
```

**Consumers:**
- **ObservabilityContext** — Enrich OpenTelemetry spans with:
  - `entity.region` — The source region
  - `entity.data_residency_zone` — The resolved zone
  - `routing.decision` — `direct_map` or `pass_through`
  - `routing.latency_ms` — Time since `region_updated_at`
- **RoutingContext** — Update regional routing table:
  - Maintain list of entities per zone
  - Track routing decisions for capacity planning

## Data Flow: Entity Creation with Residency Routing

```
Application Layer                    Database
─────────────────                    ────────
CreateEntityInput {
  Region: "eu-west-1"                 
}                                      │
  │                                   ▼
  │                          compute_data_residency_zone('eu-west-1')
  │                                   │
  │                                   ▼
  │                          Returns: 'eu-west-1' (one-to-one)
  │                                   │
  │                                   ▼
  │                          INSERT INTO entities (
  │                            region = 'eu-west-1',
  │                            data_residency_zone = 'eu-west-1' (GENERATED)
  │                            region_updated_at = NOW()
  │                          )
  │                                   │
  │                                   ▼
  │                          INSERT INTO outbox_events (
  │                            event_type = 'entitymanagement.entity.created',
  │                            payload = { entity_id, region, zone, ... }
  │                          )
  │                                   │
  │                                   ▼
  │                          INSERT INTO outbox_events (
  │                            event_type = 'entitymanagement.residency.region_routed',
  │                            payload = { entity_id, region, zone, routing_decision }
  │                          )
  │                                   │
  ▼                                   ▼
Outbox Relay ──────────► NATS ──────────► ObservabilityContext
                                              │
                                              ├── Enrich span: region="eu-west-1"
                                              ├── Enrich span: data_residency_zone="eu-west-1"
                                              └── Enrich span: routing_decision="direct_map"
```

## Caching Strategy (Redis)

Configuration: `config/redis_residency.conf`

| Cache Key Pattern | TTL | Purpose |
|---|---|---|
| `residency:zone:{region}` | 1 hour | Region → zone resolution (expensive recompute) |
| `residency:entity:{id}:zone` | 5 min | Entity's zone + routing decision |
| `residency:routing_table:{zone}` | 30 sec | Active routing entries per zone |
| `residency:observability:{id}` | 2 min | Span enrichment data |
| `residency:zone_counts` | 1 min | Cached zone distribution |
| `residency:zone_entities:{zone}:{status}` | 30 sec | Cached entity list per zone |

Cache invalidation is triggered by:
- `entitymanagement.residency.region_routed` → Invalidate zone + routing caches
- `entitymanagement.entity.created` → Invalidate zone counts + lists
- `entitymanagement.entity.soft_deleted` → Invalidate zone entities lists

## Seed Data

File: `entity-management/database/seeds/ENTITYMGMT-11_000_multi_region_data_residency_seed.sql`

| Seed | Entity ID | Region | Expected Zone | Scenario |
|---|---|---|---|---|
| EU-Customer-Alice | `e1100001-...-001` | `eu-west-1` | `eu-west-1` | SCENARIO 1: eu-west-1 zone resolution |
| US-Customer-Bob | `e1100001-...-002` | `us-east-1` | `us-east-1` | SCENARIO 1: us-east-1 zone resolution |
| Custom-Region-Entity | `e1100001-...-003` | `custom-region-1` | `custom-region-1` | SCENARIO 2: unknown pass-through |

The seed also pre-populates:
- 3 `region_routed` outbox events (one per entity)
- Verification of immutable field rejection (SCENARIO 3)
- Diagnostic function demonstrations

## Down Migration Impact

The down migration reverts the zone mapping to the original group-based system:
- `eu-west-1` → `'eu'` (was `'eu-west-1'`)
- `us-east-1` → `'us'` (was `'us-east-1'`)
- Unknown regions → `'other'` (was pass-through)

**Warning**: This is a destructive change for entities created with the new
mapping. Their `data_residency_zone` will be recomputed to the old values.
Ensure downstream consumers (ObservabilityContext, RoutingContext) are
aware of the reversion before rolling back.
