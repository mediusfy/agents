# CLUSTER-02 Migration Guide: Unified Cross-Cluster Resource View

## Migration Details

| Property | Value |
|----------|-------|
| **Migration ID** | 008 |
| **Story** | CLUSTER-02 |
| **Description** | Unified Cross-Cluster Resource View |
| **Type** | Schema + Materialized Views + Seed Data |
| **Dependencies** | CLUSTER-01 (`cluster_connections`), pg_trgm extension |

## What's Included

### New Objects Created

- **10 Tables** (categories, types, namespaces, resources, labels, conditions, owners, metrics, snapshots, saved views)
- **2 Materialized Views** (cross-cluster summary, namespace summary)
- **5 ENUM Types** (health, sync_status, phase, visibility, snapshot_reason)
- **3 Functions** (search_resources_by_label, refresh_matviews, log_resource_change)
- **2 Triggers** (modtime updates, matview refresh notification)
- **40+ Indexes** (B-Tree, GIN, GIN trgm, composite, partial, unique)
- **1 Partitioned Table** (cluster_resource_snapshots - monthly)

### Seed Data

- 10 resource categories (Workloads, Networking, Storage, Configuration, RBAC, etc.)
- 40+ standard Kubernetes resource types with API versions
- 5 default saved views (All Resources, Unhealthy, Workload Overview, Pods View, Sync Issues)

## Dependencies

```sql
-- Required extensions (add to initial setup migration if not present)
CREATE EXTENSION IF NOT EXISTS pg_trgm;
-- Optional: pg_partman for automated partition management
-- CREATE EXTENSION IF NOT EXISTS pg_partman;
```

## Migration Steps

### 1. Apply the up migration
```bash
psql -h $PGHOST -d $PGDATABASE -f docs/migrations/008_cluster_02_unified_resource_view.up.sql
```

### 2. Seed reference data
```bash
psql -h $PGHOST -d $PGDATABASE -f docs/database/seeds/008_cluster_02_resource_view_seed.sql
```

### 3. Initialize partition management (optional)
```sql
-- If using pg_partman for automated snapshot partitioning
SELECT partman.create_parent(
    p_parent_table := 'public.cluster_resource_snapshots',
    p_control := 'snapshot_date',
    p_type := 'native',
    p_interval := '1 month',
    p_start_partition := (CURRENT_DATE - INTERVAL '3 months')::TEXT,
    p_premake := 3
);
```

### 4. Configure Redis cache
Copy the Redis config to your Redis instances:
```bash
cp docs/infrastructure/redis/cluster02-resource-view-cache.conf /etc/redis/cluster02-resource-view.conf
```

### 5. Test the materialized views
```sql
-- Refresh materialized views
SELECT refresh_cluster_resource_matviews();

-- Query cross-cluster summary
SELECT * FROM cross_cluster_resource_summary;

-- Query namespace summary
SELECT * FROM cluster_namespace_summary;
```

## Rollback

```bash
psql -h $PGHOST -d $PGDATABASE -f docs/migrations/008_cluster_02_unified_resource_view.down.sql
```

## Performance Considerations

### Expected Data Volume
- **cluster_resources**: 10K-500K rows (depending on cluster fleet size)
- **cluster_resource_labels**: 5x-20x resource count (avg labels per resource)
- **cluster_resource_conditions**: 2x-5x resource count (avg conditions per resource)
- **cluster_resource_snapshots**: 30x monthly growth of active resources

### Query Patterns
| Pattern | Index Used | Expected Performance |
|---------|-----------|---------------------|
| List resources by cluster + kind | `idx_resources_cluster_kind` | < 5ms at 500K rows |
| Search by label key=value | GIN on labels | < 10ms |
| Search by name (fuzzy) | GIN trgm on name | < 20ms |
| Health dashboard aggregation | Materialized view | < 2ms |
| Full text search across clusters | GIN trgm + composite indexes | < 50ms |

### Caching Recommendations
- **API Layer**: Use Redis cache for list/detail endpoints (30-60s TTL)
- **Dashboard Layer**: Use materialized views directly (refresh every 30-120s)
- **Search Layer**: Consider Elasticsearch for advanced full-text search

## Cross-Cluster Constraints

This schema supports the following multi-cloud constraints:

1. **Resource UID uniqueness per cluster** - `UNIQUE (cluster_id, resource_uid)`
2. **Name uniqueness per namespace+type+cluster** - `UNIQUE (cluster_id, namespace_id, resource_type_id, name)`
3. **Cluster-scoped resources** - `namespace_id` is nullable for cluster-scope resources (Nodes, ClusterRoles, etc.)
4. **Sync isolation** - Each cluster's agent syncs independently; `sync_status` tracks per-resource sync state
5. **Stale detection** - `last_synced_at` enables detection of stale resources (not updated within expected interval)
