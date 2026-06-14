# ENTITYMGMT-11 — Multi-Region Data Residency

## Artifact Inventory

```
entity-management/
  database/
    migrations/
      ENTITYMGMT-11_000_multi_region_data_residency.up.sql
              (12 sections: 36208 chars)
      ENTITYMGMT-11_000_multi_region_data_residency.down.sql
              (11 sections: 13102 chars)
    seeds/
      ENTITYMGMT-11_000_multi_region_data_residency_seed.sql
              (8 seeds: 16840 chars)
    queries/
      ENTITYMGMT-11_resolve_zone.sql
              (7 queries: 6388 chars)

config/
  redis_residency.conf
              (Redis config: 6045 chars)

docs/
  entity-management/
    ENTITYMGMT-11_multi_region_data_residency.md
              (Documentation: 10564 chars)
```

## Gherkin Coverage

| Scenario | Coverage |
|----------|----------|
| SCENARIO 1: Entity creation resolves zone (eu-west-1) | ✅ Seed 2, 4 — entity `e1100001-...-001` |
| SCENARIO 1: Observability spans enriched | ✅ Seed 3, 6 — region_routed event emitted |
| SCENARIO 2: eu-west-1 → eu-west-1 | ✅ Seed 1 — compute_data_residency_zone() verified |
| SCENARIO 2: us-east-1 → us-east-1 | ✅ Seed 1 — compute_data_residency_zone() verified |
| SCENARIO 2: Unknown pass-through | ✅ Seed 1, 2 — `custom-region-1` passes through |
| SCENARIO 3: Immutable zone rejection | ✅ Seed 5 — trigger blocks region update |
| SCENARIO 3: No data modification | ✅ Seed 5 — zone unchanged after failed update |
| Event: region_routed payload | ✅ Seed 6 — all 5 fields verified |

## Key Design Decisions

1. **One-to-one mapping**: Rather than collapsing regions into groups
   ('eu', 'us'), each known region maps to ITSELF as the residency zone.
   This simplifies routing logic and supports per-region observability.

2. **Unknown pass-through**: Previously, unknown regions mapped to 'other'.
   Now they pass through as-is, enabling future region additions without
   migration and supporting custom/private deployments.

3. **Double immutability**: The `data_residency_zone` is protected at TWO levels:
   - PostgreSQL GENERATED ALWAYS AS column (native protection)
   - prevent_immutable_field_update trigger (clear error message)

4. **Co-emitted events**: The `entity.created` and `region_routed` events
   are emitted atomically within the same database transaction via the
   updated `enqueue_entity_created_event()` function.

5. **Generated column recreation**: Dropping and recreating the generated
   column automatically recomputes ALL existing rows with the new mapping.
   No separate data migration script needed.
