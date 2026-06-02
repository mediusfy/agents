

# BOARD-01 Database Schema: monday.com-Style Board View

## Overview

The BOARD-01 schema implements a flexible, monday.com-inspired board view system for organizing and visualizing Kubernetes resources. It provides the persistence layer for customizable boards where users can group, filter, and track resources across clusters.

## Schema Diagram

```
┌─────────────────────────┐
│         boards          │
├─────────────────────────┤
│ id (UUID PK)            │──────┐
│ name VARCHAR(255)       │      │
│ description TEXT        │      │
│ board_kind VARCHAR(50)  │      │
│ workspace_id (FK) ──────│──┐   │
│ owner_id (FK) ──────────│──│───│──┐
│ filter_config JSONB     │  │   │  │
│ sort_order INT          │  │   │  │
│ is_archived BOOL        │  │   │  │
│ created_at TIMESTAMPTZ  │  │   │  │
│ updated_at TIMESTAMPTZ  │  │   │  │
└─────────────────────────┘  │   │  │
        │                    │   │  │
        │ 1:N                │   │  │
        ▼                    │   │  │
┌─────────────────────────┐  │   │  │
│      board_groups       │  │   │  │
├─────────────────────────┤  │   │  │
│ id (UUID PK)            │  │   │  │
│ board_id (FK) ──────────┘  │   │  │
│ title VARCHAR(255)         │   │  │
│ color VARCHAR(50)          │   │  │
│ icon VARCHAR(50)           │   │  │
│ sort_order INT             │   │  │
│ is_archived BOOL           │   │  │
│ created_at TIMESTAMPTZ     │   │  │
│ updated_at TIMESTAMPTZ     │   │  │
└─────────────────────────┘  │   │  │
        │                    │   │  │
        │ 1:N                │   │  │
        ▼                    │   │  │
┌─────────────────────────┐  │   │  │
│       board_items       │  │   │  │
├─────────────────────────┤  │   │  │
│ id (UUID PK)            │  │   │  │
│ board_id (FK) ──────────┘  │   │  │
│ group_id (FK) ─────────────┘   │  │
│ title VARCHAR(500)             │  │
│ description TEXT               │  │
│ resource_id UUID               │  │
│ resource_type VARCHAR(100)     │  │
│ resource_name VARCHAR(253)     │  │
│ resource_namespace VARCHAR(253)│  │
│ cluster_id (FK) ───────────────┘  │
│ icon VARCHAR(50)                  │
│ color VARCHAR(50)                 │
│ sort_order INT                    │
│ is_archived BOOL                  │
│ created_by (FK) ──────────────────┘
│ assigned_to (FK) ─────────────────┐
│ due_date TIMESTAMPTZ              │
│ created_at TIMESTAMPTZ            │
│ updated_at TIMESTAMPTZ            │
└─────────────────────────┘         │
        │                           │
        │ 1:N                       │
        ▼                           │
┌─────────────────────────┐         │
│ board_item_column_values│         │
├─────────────────────────┤         │
│ id (UUID PK)            │         │
│ item_id (FK) ───────────┘         │
│ column_id (FK)                    │
│ value TEXT                        │
│ numeric_value NUMERIC             │
│ date_value TIMESTAMPTZ            │
│ person_value (FK) ────────────────┘
│ status_value VARCHAR(100)         │
│ created_at TIMESTAMPTZ            │
│ updated_at TIMESTAMPTZ            │
│ UNIQUE(item_id, column_id)        │
└─────────────────────────┘

┌─────────────────────────┐
│     board_columns       │ (from migration 009)
├─────────────────────────┤
│ id (UUID PK)            │──┐
│ board_id (FK) ──────────┘  │
│ title VARCHAR(255)         │
│ column_type VARCHAR(50)    │
│ settings JSONB (+)         │── Supplemented by 012
│ width INT (+)              │── Supplemented by 012
│ sort_order INT             │
│ is_archived BOOL (+)       │── Supplemented by 012
│ created_at TIMESTAMPTZ     │
│ updated_at TIMESTAMPTZ     │
└─────────────────────────┘
```

## Column Types Supported

| Type | Storage | Sorting | Notes |
|------|---------|---------|-------|
| text | value TEXT | lexicographic | General-purpose text |
| status | status_value VARCHAR | by status index order | Predefined status labels |
| date | date_value TIMESTAMPTZ | chronological | Dates and timestamps |
| numeric | numeric_value NUMERIC | numeric sort | Numbers with configurable precision |
| person | person_value UUID (FK→users) | by user name | User references |
| timeline | date_value + numeric_value | by start date | Date ranges with duration |
| color | value TEXT | lexicographic | Color picker values |
| link | value TEXT | lexicographic | URL + display text (JSON) |
| long_text | value TEXT | N/A | Rich text / markdown |
| tags | value TEXT (JSON array) | N/A | Multi-select tags |
| progress | numeric_value NUMERIC | numeric sort | 0-100 percentage |
| rating | numeric_value NUMERIC | numeric sort | Star/rating values |
| formula | value TEXT | computed | Computed from other columns |

## Index Strategy

### Core Lookups
- `idx_boards_workspace` — Filter boards by workspace
- `idx_boards_owner` — User's boards
- `idx_board_groups_board` — Groups for a board (sorted)
- `idx_board_items_board` — Items belonging to a board
- `idx_board_items_group` — Items within a group (the primary query pattern)

### Kubernetes Resource Queries
- `idx_board_items_resource` — Find all board items linked to a specific K8s resource
- `idx_board_items_cluster_ns` — Filter items by cluster + namespace

### Column Value Queries
- `idx_colval_item` — All column values for a single item (board row rendering)
- `idx_colval_column` — All values for a single column (aggregation queries)
- `idx_colval_numeric` — Numeric range queries (filter/sort by numeric columns)
- `idx_colval_status` — Status-based filtering
- `idx_colval_date` — Date range filtering
- `idx_colval_person` — Person/assignee filtering

## Migration Dependencies

**Depends on:**
- `009_board_02_board_columns` — Provides the base `board_columns` table
- `001_init` (or equivalent) — Users, workspaces tables

**Provides to:**
- Future BOARD stories (filters, sorting, board sharing)

## Caching Strategy

See `docs/redis/board_view_redis.conf` for the complete Redis caching configuration.

Key caching decisions:
- **Board structure** (layout, columns, groups): 5-min TTL, invalidated on mutation
- **Group item lists**: 1-min TTL, refreshed by K8s watch events
- **Individual items**: 30-sec TTL, near-realtime via K8s API watchers
- **Aggregation counts**: 30-sec TTL, computed from cached items

## Go Migration Usage

```go
// Example migration runner (Go)
import "github.com/pressly/goose/v3"

func main() {
    db, _ := sql.Open("postgres", os.Getenv("DATABASE_URL"))
    goose.Up(db, "docs/migrations")
}
```
