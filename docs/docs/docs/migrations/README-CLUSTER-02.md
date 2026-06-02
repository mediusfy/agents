# CLUSTER-02: Continuous Cluster Connectivity Verification & Health Monitoring

**Story:** As a platform engineer, I want the system to continuously verify cluster connectivity and show connection health, so that I can trust that board data is live.

## Migration: `007_cluster_02_connectivity_health.sql`

Depends on: `006_cluster_01_cluster_connections.sql` (CLUSTER-01)

## Schema Overview

The CLUSTER-02 migration adds the following tables to the `clusterconnect` domain:

| Table | Purpose | Partitioning |
|-------|---------|-------------|
| `connectivity_check_config` | Defines how to verify connectivity per cluster (protocol, interval, timeout, endpoint) | None |
| `connectivity_check_results` | Individual connectivity check results (pass/fail, latency, error) | Monthly (pg_partman) |
| `cluster_heartbeats` | Periodic heartbeat signals from each cluster agent | Monthly (pg_partman) |
| `cluster_certificate_expiry` | TLS certificate tracking and expiry monitoring | None |
| `cluster_health_scores` | Aggregated health scores per cluster per time window | Monthly (pg_partman) |
| `cluster_connectivity_status` | Current live connection status (denormalized latest state) | None |

### Partitioning Strategy

Uses `pg_partman` for monthly range partitioning on high-volume event tables to ensure:
- Efficient time-range queries for dashboard live views
- Automated partition management with retention policies
- Fast partition pruning for recent data

### ENUM Types

- `connectivity_protocol`: grpc, https, tcp, icmp, custom
- `check_result_type`: success, failure, timeout, error
- `cluster_health_status`: healthy, degraded, unhealthy, unknown
- `certificate_severity`: critical, warning, info

### Index Strategy

- Composite indexes on `(cluster_id, checked_at DESC)` for latest-check queries
- Partial indexes for failed/timeout checks
- GIN indexes on JSONB config fields
- BRIN indexes on time-series partition keys
