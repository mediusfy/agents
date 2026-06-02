# WORKLOAD-01 Database Schema Design

## Overview
This document describes the PostgreSQL schema for the WorkloadView bounded context. The schema implements a **CQRS cache layer** that stores Kubernetes workload resources locally for fast, inline detail sheet rendering.

## Design Principles
1. **Denormalized for performance**: K8s resources are stored as near-native JSONB fields for flexible schema evolution
2. **Multi-cluster ready**: All workload tables are cluster-scoped via `cluster_id` FK
3. **TTL-driven cache**: `last_synced_at` enables background sync workers to know what to refresh
4. **Event-driven updates**: Kubernetes events are stored separately and linked via `involved_object_uid`

## Entity Relationship Diagram (text)

```
workload_clusters
    id (PK)
    name
    api_server_url
    kube_config_ref
    region
    cloud_provider
    status
    last_healthy_at

workload_pods
    id (PK)
    cluster_id (FK -> workload_clusters)
    namespace
    name
    uid (K8s UID, unique per cluster)
    labels (JSONB)
    annotations (JSONB)
    status (JSONB - phase, conditions, containerStatuses)
    node_name
    containers (JSONB)
    resource_version
    last_synced_at
    deleted_at (soft delete)
    created_at / updated_at

workload_deployments
    id (PK)
    cluster_id (FK -> workload_clusters)
    namespace
    name
    uid (K8s UID, unique per cluster)
    labels (JSONB)
    annotations (JSONB)
    status (JSONB - replicas, readyReplicas, conditions)
    spec (JSONB - selector, strategy, template metadata)
    resource_version
    last_synced_at
    deleted_at (soft delete)
    created_at / updated_at

workload_services
    id (PK)
    cluster_id (FK -> workload_clusters)
    namespace
    name
    uid (K8s UID, unique per cluster)
    labels (JSONB)
    annotations (JSONB)
    spec (JSONB - ports, type, clusterIP, selector)
    status (JSONB - loadBalancer ingress)
    resource_version
    last_synced_at
    deleted_at (soft delete)
    created_at / updated_at

workload_events
    id (PK)
    cluster_id (FK -> workload_clusters)
    namespace
    name (event name)
    involved_object_kind (Pod|Deployment|Service)
    involved_object_name
    involved_object_uid
    reason
    message
    source (JSONB - component, host)
    first_timestamp
    last_timestamp
    count
    type (Normal|Warning)
    last_synced_at
    created_at / updated_at
```

## Indexing Strategy
- Composite index on (cluster_id, namespace, name) for resource lookups
- GiST/GIN indexes on JSONB labels/annotations for flexible filtering
- Index on `deleted_at` for soft-delete filtering
- Index on `last_synced_at` for sync worker queries
- Index on `involved_object_uid` in events table

## Redis Caching Strategy
- Short-lived cache (TTL: 30s) for frequently accessed workload lists
- Cache key format: `workload:{cluster}:{kind}:{namespace}:{name}`
- Invalidation via event-driven cache eviction on sync completion
