# Migration: 011_clusterconnect_02_connection_status

## Story
**CLUSTERCONNECT-02**: Unified Cluster List with Connection Status Indicators

## Summary
Adds the `cluster_connections` table, a `cluster_connection_status` enum with 6 states, a `cluster_health_checks` table partitioned by month, and a convenience view `v_cluster_list_with_health` that joins clusters with their latest health metrics.

## Files

| File | Purpose |
|------|---------|
| `docs/database/migrations/011_clusterconnect_02_connection_status.sql` | Up/Down migration |
| `docs/database/seeds/011_clusterconnect_02_seed.sql` | Sample seed data |
| `docs/redis/clusterconnect_02_cache.conf` | Redis cache configuration |
| `docs/docs/database/CLUSTERCONNECT-02-schema-doc.md` | Full schema documentation |

## Design Decisions

1. **Enum over string column**: Using a PostgreSQL enum for `connection_status` ensures data integrity and enables efficient filtering.

2. **Partitioned health checks**: `cluster_health_checks` is RANGE-partitioned by `checked_at` (monthly). This keeps query performance consistent as data grows and simplifies archival.

3. **View with LATERAL JOIN**: A regular view (`v_cluster_list_with_health`) with a `LATERAL JOIN` retrieves the single latest health check per cluster. This avoids a materialized view since the underlying data changes frequently. The application layer caches the result in Redis.

4. **Two-phase partition creation**: Only current and next-month partitions are created in the migration. A scheduler job creates future partitions proactively.

5. **Status indicator mapping**: The view maps enum values to UI-friendly indicator names (`healthy`, `degraded`, `warning`, `critical`, `pending`, `unknown`), decoupling the database from presentation logic.

6. **Idempotent migration**: Uses `CREATE TABLE IF NOT EXISTS`, `CREATE OR REPLACE`, and `IF NOT EXISTS` throughout so it can safely run alongside or after CLUSTERCONNECT-01.

## Dependencies

- PostgreSQL 13+ (for partitioned tables)
- Run after any CLUSTERCONNECT-01 migration if `cluster_connections` already exists

## Rollback

The DOWN section of the migration will:
1. Drop the view `v_cluster_list_with_health`
2. Drop all indexes
3. Drop the `cluster_health_checks` partitioned table and its partitions
4. Drop the `cluster_connections` table
5. Drop the `cluster_connection_status` enum type

## Redis Cache Invalidation

When a cluster's status changes:
1. Application updates `cluster_connections.connection_status`
2. Application publishes a Redis `PUBLISH cluster:status:changed {cluster_id}`
3. Cache listener evicts `cluster:list:all` and `cluster:{id}:detail`
4. Next read re-populates from `v_cluster_list_with_health`
