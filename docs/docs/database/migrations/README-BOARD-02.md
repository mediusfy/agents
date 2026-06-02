

# BOARD-02 — Customizable Board Column Configuration

## Overview

This migration introduces the board management schema for the `board-service`,
a multi-region hexagonal Go service that powers the Rufkis Kubernetes console's
Kanban-style board views.

**Requirement:** R1 (global control-plane / per-region data-plane separation),
R5 (audit WAL), R6 (materialised resource cache), R9 (local board state only).

---

## Table Reference

| # | Table | Purpose | Partitioned |
|---|-------|---------|-------------|
| 1 | `boards` | Core board entity with filter criteria & optimistic locking | No |
| 2 | `board_columns` | Column configuration (position, colour, card limit, filter/sort) | No |
| 3 | `board_cards` | Materialised cards (resource representations) inside columns | No |
| 4 | `board_templates` | Reusable templates for rapid board creation | No |
| 5 | `board_managed_resources` | Materialised cache of K8s resources per board (R6) | No |
| 6 | `audit_wal` | Append-only WAL-style audit log (R5) | **LIST by region** |
| 7 | `region_cluster_mapping` | Tracks cluster → region assignment | No |

---

## Key Design Decisions

### UUIDv7 Primary Keys
All PKs use `public.gen_uuid_v7()` — a UUIDv7 generator that embeds a Unix-millisecond
timestamp, providing **temporal ordering** (B-tree friendly) and **collision-free**
generation across regions. The shim function works on PostgreSQL 13+; PG 17+ can
substitute the native `gen_uuid_v7()`.

### JSONB Indexing Strategy
- **`filter_criteria`** on `boards` — GIN index with `jsonb_path_ops` for top-level board filtering
- **`filter_expression`** on `board_columns` — GIN for per-column resource predicates
- **`card_metadata`** on `board_cards` — GIN for searching card attributes
- **`labels`** / **`annotations`** / **`status`** on `board_managed_resources` — GIN for K8s-style label selectors
- **`payload`** on `audit_wal` — GIN for forensic ad-hoc queries

### Composite Indexes for Board-Loading
The most latency-sensitive query is "load a board with all its columns and cards":
1. `idx_board_columns_board_position` — `(board_id, position)` → columns ordered
2. `idx_board_cards_board_column_pos` — `(board_id, column_id, position)` → all cards in display order
3. `idx_bmr_board` — `(board_id)` → all cached resources for reconciliation

### `audit_wal` Partitioning
- **LIST partition on `region`** — each region's audit events are stored in its own partition,
  providing natural data-plane isolation and simplifying region-level retention policies.
- A `DEFAULT` partition catches events from unregistered regions.
- Partitions should be pre-created by the provisioning pipeline (e.g., `audit_wal_us_east_1`).

### Chain Links
`chain_link_id` and `chain_prev_id` are populated **asynchronously** by the
background worker function `audit_wal_link_chain()`, which processes up to 1000
unlinked rows every second. This avoids blocking the hot write path.

### Optimistic Locking on `boards`
The `version` column is incremented on every update. The application should
use `UPDATE ... WHERE id = $1 AND version = $2` and retry on conflict.

---

## Query Patterns

### Load a full board for rendering
```sql
SELECT b.*, c.*, ca.*
FROM boards b
LEFT JOIN board_columns c ON c.board_id = b.id
LEFT JOIN board_cards ca ON ca.board_id = b.id AND ca.column_id = c.id
WHERE b.id = ?
ORDER BY c.position, ca.position;
```

### Find all resources matching a column's filter
```sql
SELECT r.*
FROM board_managed_resources r
JOIN board_columns c ON c.board_id = r.board_id
WHERE c.id = ?
  AND r.gvk = ANY (jsonb_path_query_array(c.filter_expression, '$.gvk')::text[])
  AND r.labels @> (c.filter_expression -> 'labels')
  AND r.status @> (c.filter_expression -> 'status');
```

### Link audit events (background worker)
```sql
SELECT public.audit_wal_link_chain(1000);
```

---

## Seed Data

The seed script (`009_board_02_seed.sql`) creates:
- 2 reusable templates ("Standard Pipeline", "Cluster Health")
- 1 sample board "Team Sigma Dashboard" with 3 columns
- 5 region-cluster mappings across us-east-1, us-west-2, eu-west-1, and global

---

## Test Fixtures

For integration tests, the Go test suite should:
1. Run the up migration
2. Insert a test board via the `boards` repository
3. Add columns via the `board_columns` repository
4. Simulate Kafka events that flow into `board_cards` / `board_managed_resources`
5. Assert the `GET /boards/:id` endpoint returns correctly ordered columns with cards
