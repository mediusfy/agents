# CLUSTERCONNECT-02: Unified Cluster List with Connection Status

## Story
> **As an** operations engineer
> **I want to** view all my connected clusters in a unified list with connection status indicators
> **So that** I can quickly see which clusters are reachable and which have issues

## Schema Overview

This feature introduces two tables and one view.

### `cluster_connections`
The central table storing cluster metadata, connection configuration, and live status.

| Column | Type | Description |
|--------|------|-------------|
| `id` | `UUID` (PK) | Auto-generated primary key |
| `name` | `VARCHAR(255)` | Human-readable cluster name |
| `slug` | `VARCHAR(128)` | Unique URL-safe identifier |
| `description` | `TEXT` | Optional description |
| `api_endpoint` | `VARCHAR(1024)` | Cluster API URL |
| `dashboard_url` | `VARCHAR(1024)` | Optional link to UI dashboard |
| `region` | `VARCHAR(128)` | Cloud/on-prem region |
| `provider` | `VARCHAR(64)` | e.g. `gcp`, `aws`, `azure`, `on-prem` |
| `version` | `VARCHAR(64)` | Platform/Kubernetes version |
| `auth_type` | `VARCHAR(64)` | `api_key`, `oauth`, `mtls`, `kubeconfig` |
| `auth_config_enc` | `BYTEA` | Encrypted auth blob |
| `connection_status` | `ENUM` | See status enum below |
| `status_message` | `TEXT` | Human-readable status detail |
| `last_ping_at` | `TIMESTAMPTZ` | Last successful health check |
| `last_status_change` | `TIMESTAMPTZ` | When status last changed |
| `consecutive_failures` | `INTEGER` | Failed health checks in a row |
| `labels` | `JSONB` | Key-value tags for filtering |
| `is_active` | `BOOLEAN` | Soft delete flag |
| `created_at` | `TIMESTAMPTZ` | Row creation time |
| `updated_at` | `TIMESTAMPTZ` | Row last update time |

### `cluster_connection_status` Enum

| Value | Meaning | UI Indicator |
|-------|---------|-------------|
| `CONNECTED` | Cluster responds normally | 🟢 Healthy |
| `DEGRADED` | Partial connectivity or high latency | 🟡 Degraded |
| `DISCONNECTED` | Planned downtime / maintenance | 🟠 Warning |
| `UNREACHABLE` | No response, likely outage | 🔴 Critical |
| `PENDING` | Awaiting first health check | 🔵 Pending |
| `UNKNOWN` | Status could not be determined | ⚪ Unknown |

### `cluster_health_checks` (Partitioned by month)
Stores historical health check results, partitioned by month to handle large volumes.

| Column | Type | Description |
|--------|------|-------------|
| `id` | `UUID` (PK) | Auto-generated |
| `cluster_id` | `UUID` (FK) | References `cluster_connections.id` |
| `status` | `ENUM` | Status at check time |
| `response_time_ms` | `INTEGER` | Latency in ms |
| `http_status_code` | `SMALLINT` | HTTP response code |
| `error_message` | `TEXT` | Error details |
| `check_source` | `VARCHAR(128)` | `scheduler`, `manual`, `system_boot` |
| `metadata` | `JSONB` | Extensible check metadata |
| `checked_at` | `TIMESTAMPTZ` | When check occurred |

### `v_cluster_list_with_health` (View)
Provides the unified cluster list with the latest health check data and a computed `status_indicator` field for UI rendering.

## Indexes

### cluster_connections
- `UNIQUE (slug)` — Fast lookup by slug
- `(connection_status)` — Filter by status
- `(is_active)` — Active cluster queries
- `(region)` — Region-based filtering
- `(provider)` — Provider-based filtering
- `GIN (labels)` — JSONB label queries
- `(last_ping_at DESC)` — Recent activity sort
- `(consecutive_failures) WHERE > 0` — Problem detection
- `(last_status_change DESC)` — Recent transitions

### cluster_health_checks
- `(cluster_id)` — FK lookups
- `(cluster_id, status, checked_at DESC)` — Latest status per cluster
- `(checked_at DESC)` — Time-ordered queries
- `(status)` — Status aggregation queries

## Redis Caching Strategy

See `docs/redis/clusterconnect_02_cache.conf` for full Redis configuration.

Key patterns:
- `cluster:list:all` — Full cluster list cache (TTL: 60s)
- `cluster:list:{status}` — Filtered lists by status
- `cluster:{id}:detail` — Single cluster detail
- `cluster:stats:status` — Aggregated counts per status

## Usage Examples

### List all active clusters with health
```sql
SELECT * FROM v_cluster_list_with_health ORDER BY status_indicator, name;
```

### Find clusters with issues
```sql
SELECT * FROM cluster_connections
WHERE connection_status IN ('UNREACHABLE', 'DEGRADED')
  AND is_active = TRUE
ORDER BY consecutive_failures DESC;
```

### Get recent health check summary
```sql
SELECT
    cluster_id,
    status,
    COUNT(*) AS check_count,
    MIN(response_time_ms) AS min_latency,
    MAX(response_time_ms) AS max_latency,
    AVG(response_time_ms)::INT AS avg_latency
FROM cluster_health_checks
WHERE checked_at >= NOW() - INTERVAL '1 hour'
GROUP BY cluster_id, status;
```

## Data Lifecycle
- Health checks older than 90 days should be archived to cold storage.
- Partition management is handled via a cron job that creates new monthly partitions and detaches old ones.
- Soft-deleted clusters (`is_active = FALSE`) retain their health history for audit purposes.
