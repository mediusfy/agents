

# RESOURCE-01: Deployment Board Migration Guide

## Story
**As an** operations engineer
**I want** to view all Deployments running in a selected cluster and namespace organized on a board
**So that** I can understand the current workload state at a glance

## Migration Overview
- **Migration File:** `002_resource_01_deployment_board.sql`
- **Seed File:** `002_resource_01_deployment_board_seed.sql`
- **Redis Config:** `redis/resource-01-cache.conf`

## What's Created

### ENUM Types
| Type | Values | Purpose |
|------|--------|---------|
| `deployment_status` | `Running`, `Pending`, `Failed`, `ScalingUp`, `ScalingDown`, `Unknown`, `Paused`, `Progressing` | Canonical set of Kubernetes deployment health states |

### Tables
| Table | Description |
|-------|-------------|
| `deployment_boards` | Board configurations scoped to a specific cluster + namespace |
| `deployment_board_columns` | Columns that organize deployments by status (kanban-style) |
| `deployment_board_cards` | Links deployments to their board column and position |
| `deployment_status_events` | Immutable audit log of deployment status transitions |

### Materialized View
| View | Description |
|------|-------------|
| `mv_deployment_board_snapshot` | Pre-joined board data for fast reads; refreshed via `REFRESH MATERIALIZED VIEW CONCURRENTLY` |

### Indexes
- **GIN** indexes on `labels` (JSONB) and `annotations` (JSONB) for flexible querying
- **BRIN** index on `created_at` for time-range scans on large tables
- **Composite** indexes on `(board_id, column_id, position)` for board ordering
- **Covering** indexes on `(deployment_id, new_status)` for status history queries
- **Full-text** search index on deployment `name` for quick filtering

## Dependencies
- **CLUSTER-01** migration (provides `clusters`, `namespaces` tables)
- **WORKLOAD-01** migration (provides `deployments` table)

## Refresh Strategy
The materialized view `mv_deployment_board_snapshot` can be refreshed via:
```sql
-- After any deployment status changes
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_deployment_board_snapshot;
```
A cron job or PostgreSQL `pg_cron` extension should refresh this every 30 seconds.
