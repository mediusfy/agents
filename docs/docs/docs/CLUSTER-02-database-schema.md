# CLUSTER-02: Cluster Connectivity & Health Monitoring Schema

## Domain Overview

The CLUSTER-02 bounded context extends the ClusterConnect bounded context from CLUSTER-01
by adding continuous connectivity verification, real-time heartbeat monitoring,
certificate lifecycle tracking, and health status aggregation.

This enables the "live" health indicators on the Rufkis dashboard, showing platform
engineers which clusters are healthy, degraded, or unreachable.

## Entity-Relationship Summary

```
cluster_connections (CLUSTER-01)
  ├──> connectivity_check_config      (1:N)   - How to verify connectivity
  ├──> connectivity_check_results     (1:N)   - Individual check outcomes (partitioned)
  ├──> cluster_heartbeats             (1:N)   - Periodic agent pings (partitioned)
  ├──> cluster_certificate_expiry     (1:N)   - TLS certificate tracking
  ├──> cluster_health_scores          (1:N)   - Aggregated metrics (partitioned)
  └──> cluster_connectivity_status    (1:1)   - Current live status (denormalized)
```

## Table Details

### `connectivity_check_config`
- Defines per-cluster health check parameters
- Multiple protocols supported (grpc, https, tcp, icmp, custom)
- Configurable intervals, timeouts, retries, and failure thresholds
- Soft-delete support, unique active config per (cluster, protocol, endpoint)
- JSONB metadata for protocol-specific configuration

### `connectivity_check_results` (Monthly Partitioned)
- Stores every individual check result
- Partitioned by `checked_at` using pg_partman for efficient pruning
- Includes latency, status code, and error messages
- Indexed for quick "latest check per cluster" queries
- Partial indexes for failure/timeout/error results
- BRIN index for partition pruning

### `cluster_heartbeats` (Monthly Partitioned)
- Fine-grained heartbeat pings from cluster agents
- Includes resource usage telemetry (node/pod counts, CPU/memory)
- JSONB metadata for flexible agent telemetry
- Partitioned by `received_at`

### `cluster_certificate_expiry`
- Tracks TLS certificates for each cluster
- Generated column `days_until_expiry` for computed remaining days
- Severity classification: critical (<7 days), warning (7-30), info (>30)
- Self-referential FK for renewal tracking
- Soft-delete support, unique fingerprint tracking

### `cluster_health_scores` (Monthly Partitioned)
- Pre-aggregated health metrics per time window
- Window types: 1m, 5m, 15m, 1h, 1d
- Generated column `uptime_pct` calculated from success/total ratio
- Latency percentiles (p50, p95, p99) for performance monitoring
- Unique constraint on (cluster_id, window_start, window_type)

### `cluster_connectivity_status`
- Denormalized current status for each cluster
- Updated via triggers on check_results and heartbeats
- Includes all key indicators: reachable, latency, uptime, cert status
- Single row per cluster (1:1 with cluster_connections)
- Partial indexes for unhealthy/expiring clusters

## Automated Behavior

| Trigger | Source Table | Action |
|---------|-------------|--------|
| `trg_check_result_update_status` | connectivity_check_results | Updates cluster_connectivity_status |
| `trg_heartbeat_update_status` | cluster_heartbeats | Updates last_heartbeat_at and telemetry |
| `trg_init_connectivity_status` | cluster_connections | Creates initial status row |
| `trg_init_default_check_config` | cluster_connections | Creates default HTTPS check config |

## Partitioning Strategy

Three tables use pg_partman monthly range partitioning:
1. `connectivity_check_results` - by `checked_at`
2. `cluster_heartbeats` - by `received_at`
3. `cluster_health_scores` - by `window_start`

Retention: 12 months with auto-drop expired partitions.

## Cache Strategy (Redis)

See `docs/infrastructure/redis/cluster02-health-cache.conf` for full details.
Key cache layers:
- **cluster:health:{id}** (TTL: 10s) - Live health indicator
- **cluster:heartbeat:{id}** (TTL: 30s) - Latest telemetry
- **cluster:healthscore:{id}:{window}** (TTL: 60s) - Aggregated scores
- **dashboard:health** (TTL: 15s) - Global dashboard view
- **cluster:health:events** (Pub/Sub) - Real-time status change notifications

## Migration Dependencies

- **Requires**: `006_cluster_01_cluster_connections.sql` (CLUSTER-01)
- **Migration**: `007_cluster_02_connectivity_health.sql`
- **Seed**: `007_cluster_02_seed.sql`
