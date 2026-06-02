

# WORKLOAD-01 DB Schema — Cross-Context Dependency Note

## Dependency: CLUSTER-01 (ClusterConnect)

The `workload_clusters` table in the WorkloadView bounded context is a CQRS
read-model cache that syncs K8s resource data from registered clusters. The
operational registry of cluster connections lives in the **ClusterConnect**
bounded context (migration 006).

### Expected Foreign Key (application-level, not enforced in SQL)

While we do not add a hard SQL FK from `workload_clusters` → `cluster_connections`
(to avoid cross-bounded-context coupling at the database level), the application
layer MUST ensure:

- Every `workload_clusters.cluster_id` references a valid
  `cluster_connections.id` from the ClusterConnect context.
- When a cluster is removed (soft-delete) in ClusterConnect, the corresponding
  workload cache data should be invalidated via domain events.

### Domain Event Bridge

```
ClusterConnect: ClusterRemoved
  → EventBus
  → WorkloadView: InvalidateWorkloadCache(cluster_id)
```
