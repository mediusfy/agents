# CLUSTER-02 Database Schema: Unified Cross-Cluster Resource View

## Overview

The **Unified Cross-Cluster Resource View** (CLUSTER-02) is a read-optimized bounded context within the Cluster Management domain. It provides a normalized, searchable, and aggregated view of all Kubernetes resources across every connected cluster in the multi-cloud environment.

## Bounded Context

**Domain:** Cluster Management  
**Context:** Unified Resource View (Read Model)  
**Related Contexts:** CLUSTER-01 (Cluster Connections), WORKLOAD-01 (Workload Management)  
**Pattern:** CQRS Read Model / Materialized View

## Key Concepts

| Concept | Description |
|---------|-------------|
| **Resource Catalog** | Normalized registry of every K8s resource (Pods, Deployments, Services, Nodes, etc.) across all clusters |
| **Cross-Cluster Search** | Ability to search/filter resources by name, labels, annotations, health status, and sync state across any subset of clusters |
| **Health Aggregation** | Per-resource health tracking with a standardized enum (healthy, degraded, unhealthy, unknown, pending) |
| **Ownership Graph** | Tracks parent-child resource relationships (e.g., Deployment → ReplicaSet → Pod) for topology visualization |
| **Materialized Summaries** | Pre-computed aggregation views for fast dashboard queries |
| **Saved Views** | User-configurable, filterable, shareable views of resources |

## Tables

### 1. `cluster_resource_categories`
Lookup table categorizing K8s resource types into logical groups.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID PK | Primary key |
| name | VARCHAR(64) UNIQUE | Display name (e.g., "Workloads") |
| slug | VARCHAR(64) UNIQUE | URL-friendly identifier |
| description | TEXT | Category description |
| icon | VARCHAR(64) | Icon identifier for UI |
| sort_order | INT | Display ordering |

### 2. `cluster_resource_types`
Registry of all known Kubernetes resource types with API versioning info.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID PK | Primary key |
| category_id | UUID FK → categories | Resource category |
| api_group | VARCHAR(128) | K8s API group (e.g., "apps", "") |
| api_version | VARCHAR(64) | API version (e.g., "v1") |
| resource_kind | VARCHAR(128) | Resource kind (e.g., "Pod") |
| resource_name_plural | VARCHAR(128) | Plural form (e.g., "pods") |
| short_name | VARCHAR(16) | CLI shorthand (e.g., "po") |
| namespaced | BOOLEAN | Whether resource is namespaced |
| scope | VARCHAR(32) | "Namespaced", "Cluster", or "Namespaced+Cluster" |

### 3. `cluster_namespaces`
Normalized catalog of all Kubernetes namespaces across clusters.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID PK | Primary key |
| cluster_id | UUID | FK to CLUSTER-01 `cluster_connections.id` |
| name | VARCHAR(253) | Namespace name (unique per cluster) |
| uid | VARCHAR(128) | K8s UID |
| status_phase | VARCHAR(32) | "Active" or "Terminating" |
| labels | JSONB | Namespace labels |
| annotations | JSONB | Namespace annotations |
| is_active | BOOLEAN | Soft delete flag |
| first_seen_at | TIMESTAMPTZ | When first discovered |
| last_seen_at | TIMESTAMPTZ | Last observed time |

**Indexes:** GIN on labels/annotations, composite on cluster+name

### 4. `cluster_resources` ⭐ (Core Table)
The central resource catalog - a normalized view of every K8s resource.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID PK | Primary key |
| cluster_id | UUID | FK to cluster_connections |
| namespace_id | UUID FK | FK to cluster_namespaces (nullable for cluster-scoped) |
| resource_type_id | UUID FK | FK to cluster_resource_types |
| resource_uid | VARCHAR(128) | K8s resource UID (unique per cluster) |
| name | VARCHAR(253) | Resource name |
| api_group / api_version / resource_kind | Denormalized | Quick filtering without joins |
| phase | ENUM | Current lifecycle phase |
| health | ENUM | Overall health status |
| sync_status | ENUM | Data synchronization state |
| labels | JSONB | K8s labels (GIN indexed) |
| annotations | JSONB | K8s annotations (GIN indexed) |
| spec / status | JSONB | Selectively extracted spec/status fields |
| owner_references | JSONB | Array of owner references |
| creation_timestamp | TIMESTAMPTZ | When resource was created in K8s |
| first_seen_at / last_seen_at / last_synced_at | TIMESTAMPTZ | Observation timestamps |
| deleted_at | TIMESTAMPTZ | Soft delete (resource removed from cluster) |

**Indexes:** 20+ indexes including GIN on JSONB, composite on (cluster, kind), (cluster, health), trigram on name, partial on active resources

### 5. `cluster_resource_labels`
Normalized label key-value pairs for efficient label-based queries.

| Column | Type | Description |
|--------|------|-------------|
| resource_id | UUID FK | FK to cluster_resources (CASCADE) |
| key | VARCHAR(253) | Label key |
| value | TEXT | Label value |

### 6. `cluster_resource_conditions`
K8s-style condition tracking (e.g., Pod Ready=True, Deployment Available=True).

| Column | Type | Description |
|--------|------|-------------|
| resource_id | UUID FK | FK to cluster_resources (CASCADE) |
| type | VARCHAR(128) | Condition type (e.g., "Ready") |
| status | VARCHAR(32) | "True", "False", "Unknown" |
| reason | VARCHAR(256) | Machine-readable reason |
| message | TEXT | Human-readable message |
| last_transition_time | TIMESTAMPTZ | When condition last changed |

### 7. `cluster_resource_owners`
Normalized owner reference graph for resource topology.

| Column | Type | Description |
|--------|------|-------------|
| child_resource_id | UUID FK | Child resource (e.g., Pod) |
| parent_resource_id | UUID FK | Parent resource (e.g., ReplicaSet) |
| owner_uid | VARCHAR(128) | K8s UID of owner |
| owner_kind | VARCHAR(128) | Kind of owner |
| owner_name | VARCHAR(253) | Name of owner |
| controller | BOOLEAN | Whether owner is controlling |

### 8. `cluster_resource_metrics`
Time-series resource utilization metrics.

| Column | Type | Description |
|--------|------|-------------|
| resource_id | UUID FK | FK to cluster_resources |
| metric_name | VARCHAR(128) | "cpu_usage", "memory_usage", etc. |
| metric_value | DOUBLE PRECISION | Numeric value |
| metric_unit | VARCHAR(32) | "cores", "bytes", "millicores" |
| recorded_at | TIMESTAMPTZ | When metric was sampled |

### 9. `cluster_resource_snapshots`
Monthly-partitioned historical snapshots for audit/timeline views.

| Column | Type | Description |
|--------|------|-------------|
| (same base fields as cluster_resources) | | Snapshot of key fields |
| snapshot_date | DATE | Partition key |
| snapshot_reason | VARCHAR(64) | "scheduled", "event", "manual", "change_detected" |
| changes_since_last | JSONB | Diff from previous snapshot |

**Partitioning:** Monthly via native PostgreSQL partitioning (pg_partman-compatible)

### 10. `saved_resource_views`
User-configurable, filterable, and shareable resource views.

| Column | Type | Description |
|--------|------|-------------|
| owner_id | UUID | Owner user ID |
| name | VARCHAR(256) | View name (unique per owner) |
| filters | JSONB | Filter configuration (clusters, kinds, labels, health, etc.) |
| columns_config | JSONB | Visible column configuration |
| sort_config | JSONB | Default sort specification |
| visibility | ENUM | "private", "team", "organization" |

## Materialized Views

### `cross_cluster_resource_summary`
Aggregated statistics per (cluster, resource_kind).

**Columns:** cluster_id, resource_kind, category, total/active/deleted counts, health breakdown, sync status breakdown, phase breakdown

### `cluster_namespace_summary`
Aggregated per-namespace statistics across clusters.

**Columns:** cluster_id, namespace_name, status_phase, total/healthy/unhealthy resources, resources_by_kind (JSONB), latest_activity

## Key Functions

| Function | Description |
|----------|-------------|
| `search_resources_by_label(key, operator, value, values[])` | Label-based resource search |
| `refresh_cluster_resource_matviews()` | Concurrent refresh of all materialized views |

## Indexing Strategy

| Index Type | Target | Purpose |
|------------|--------|---------|
| B-Tree | cluster_id, resource_kind | Primary access patterns |
| GIN | labels, annotations | JSONB key-value search |
| GIN | spec, status | Spec/status field queries |
| GIN (trgm) | name | Fuzzy name search |
| Composite | (cluster, namespace, kind) | Common multi-cluster filter |
| Composite | (cluster, health) | Health monitoring dashboards |
| Partial | active resources | Most common query scope |
| Partial | deleted resources | Cleanup/reconciliation queries |
| Unique | cluster + resource_uid | Idempotent ingestion |

## Cache Strategy (Redis)

Cache layer sits between the API and PostgreSQL to handle high-read traffic.

| Cache Key Pattern | TTL | Purpose |
|------------------|-----|---------|
| `resource:list:{cluster}:{kind}:{ns}:{hash}` | 30s | Paginated listings |
| `resource:detail:{id}` | 60s | Single resource |
| `resource:summary:{cluster}` | 120s | Aggregated summaries |
| `resource:namespace:{cluster}` | 120s | Namespace list |
| `resource:label-index:{key}:{hash}` | 300s | Label query results |
| `resource:search:{term}:{hash}` | 60s | Full-text search |

## Integration Points

| Integration | Direction | Description |
|-------------|-----------|-------------|
| **CLUSTER-01** | Reads `cluster_connections.id` | Identifies clusters for resource discovery |
| **CLUSTER-02 Health** | Coexists | Health service writes to `cluster_resources.health` |
| **WORKLOAD-01** | Consumer | Workload management reads resource topology |
| **Event Bus** | Producer | Resource changes → `pg_notify` → event bus |
| **Audit Log** | Producer | Resource mutations logged to CLUSTER-01 audit tables |

## Events

The schema emits the following events via PostgreSQL triggers and `pg_notify`:

| Event Channel | Payload | Trigger |
|---------------|---------|---------|
| `refresh_resource_matviews` | (empty) | Any INSERT/UPDATE/DELETE on cluster_resources |
| `resource_health_change` | resource_id, old_health, new_health | UPDATE on cluster_resources.health |
| `resource_sync_status_change` | resource_id, old_status, new_status | UPDATE on cluster_resources.sync_status |

## Migration

- **Up:** `docs/migrations/008_cluster_02_unified_resource_view.up.sql`
- **Down:** `docs/migrations/008_cluster_02_unified_resource_view.down.sql`
- **Seed:** `docs/database/seeds/008_cluster_02_resource_view_seed.sql`
- **Redis Config:** `docs/infrastructure/redis/cluster02-resource-view-cache.conf`
