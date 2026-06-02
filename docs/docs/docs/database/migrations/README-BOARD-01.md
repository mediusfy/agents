

# BOARD-01: monday.com-Style Board View for Kubernetes Resources

## Overview

This migration introduces the foundational schema for a monday.com-style board view system tailored for Kubernetes resource management. The design enables users to create customizable boards with groups, columns, and items representing Kubernetes resources (Pods, Deployments, Services, etc.).

## Domain Model

The board view follows a hierarchical structure:

```
Board
 ├── Board Group (horizontal swimlane, e.g., "Running", "Pending", "Failed")
 │    ├── Board Item (Kubernetes resource or task)
 │    │    ├── Column Value (value for each column)
 │    │    └── ...
 │    └── Board Item
 ├── Board Group
 │    ├── Board Item
 │    └── ...
 └── Board Columns (vertical data fields across all groups)
      ├── "Status" (status column)
      ├── "Namespace" (text column)
      ├── "CPU" (numeric column)
      └── ...
```

## Tables

### `boards`
Top-level board definitions. Each board represents a customizable view into Kubernetes resources, similar to a monday.com board.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID PK | Unique identifier |
| name | VARCHAR(255) NOT NULL | Board display name |
| description | TEXT | Optional board description |
| board_kind | VARCHAR(50) DEFAULT 'main' | Board type: main, private, shared, template |
| workspace_id | UUID FK → workspaces(id) | Workspace this board belongs to |
| owner_id | UUID FK → users(id) | Board owner/creator |
| filter_config | JSONB | K8s resource filter criteria (cluster, namespace, resource type, labels) |
| sort_order | INTEGER DEFAULT 0 | Display ordering |
| is_archived | BOOLEAN DEFAULT FALSE | Soft-delete flag |
| created_at | TIMESTAMPTZ | Creation timestamp |
| updated_at | TIMESTAMPTZ | Last update timestamp |

### `board_groups`
Horizontal groups/lanes within a board (like monday.com groups or Trello lists). Groups can represent status categories (e.g., "Running", "Pending", "Failed") or namespace groupings.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID PK | Unique identifier |
| board_id | UUID FK → boards(id) ON DELETE CASCADE | Parent board |
| title | VARCHAR(255) NOT NULL | Group display name |
| color | VARCHAR(50) | Accent color for the group header |
| icon | VARCHAR(50) | Optional icon identifier |
| sort_order | INTEGER DEFAULT 0 | Display ordering within board |
| is_archived | BOOLEAN DEFAULT FALSE | Soft-delete flag |
| created_at | TIMESTAMPTZ | Creation timestamp |
| updated_at | TIMESTAMPTZ | Last update timestamp |

### `board_columns` (supplemented from 009)
Column definitions for each board. Each column represents a data field (text, status, date, person, numeric, timeline, etc.).

| Column | Type | Description |
|--------|------|-------------|
| id | UUID PK | Unique identifier |
| board_id | UUID FK → boards(id) ON DELETE CASCADE | Parent board |
| title | VARCHAR(255) NOT NULL | Column header display name |
| column_type | VARCHAR(50) NOT NULL | Column type: text, status, date, person, numeric, timeline, color, link, rating, etc. |
| settings | JSONB | Column-specific configuration (e.g., status options, date format) |
| width | INTEGER DEFAULT 200 | Column display width in pixels |
| sort_order | INTEGER DEFAULT 0 | Display ordering |
| is_archived | BOOLEAN DEFAULT FALSE | Soft-delete flag |
| created_at | TIMESTAMPTZ | Creation timestamp |
| updated_at | TIMESTAMPTZ | Last update timestamp |

### `board_items`
Individual items/rows in a board. Each item typically represents a Kubernetes resource (Pod, Deployment, Service, etc.) or a related task/action item.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID PK | Unique identifier |
| board_id | UUID FK → boards(id) ON DELETE CASCADE | Parent board |
| group_id | UUID FK → board_groups(id) ON DELETE SET NULL | Group this item belongs to |
| title | VARCHAR(500) NOT NULL | Item display title |
| description | TEXT | Detailed description |
| resource_id | UUID | FK to the K8s resource (polymorphic) |
| resource_type | VARCHAR(100) | K8s resource type: pod, deployment, service, ingress, configmap, etc. |
| resource_name | VARCHAR(253) | K8s resource name (denormalized for quick display) |
| resource_namespace | VARCHAR(253) | K8s namespace (denormalized) |
| cluster_id | UUID FK → clusters(id) ON DELETE SET NULL | Source cluster |
| icon | VARCHAR(50) | Icon identifier for the item |
| color | VARCHAR(50) | Accent color |
| sort_order | INTEGER DEFAULT 0 | Display ordering within group |
| is_archived | BOOLEAN DEFAULT FALSE | Soft-delete flag |
| created_by | UUID FK → users(id) | Item creator |
| assigned_to | UUID FK → users(id) | Item assignee |
| due_date | TIMESTAMPTZ | Optional due date |
| created_at | TIMESTAMPTZ | Creation timestamp |
| updated_at | TIMESTAMPTZ | Last update timestamp |

### `board_item_column_values`
Stores the actual values for each board item in each column. Uses a polymorphic value pattern to support different column types efficiently.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID PK | Unique identifier |
| item_id | UUID FK → board_items(id) ON DELETE CASCADE | Board item |
| column_id | UUID FK → board_columns(id) ON DELETE CASCADE | Board column |
| value | TEXT | Raw/serialized value (type-specific) |
| numeric_value | NUMERIC | Numeric value for sorting/computation |
| date_value | TIMESTAMPTZ | Date value for date-based columns |
| person_value | UUID FK → users(id) | Person reference for person columns |
| status_value | VARCHAR(100) | Status index/label for status columns |
| created_at | TIMESTAMPTZ | Creation timestamp |
| updated_at | TIMESTAMPTZ | Last update timestamp |

**Unique constraint**: (item_id, column_id) - one value per item per column.

## Index Strategy

| Index | Purpose |
|-------|---------|
| idx_boards_workspace | Fast workspace-scoped board listing |
| idx_boards_owner | User-owned board queries |
| idx_board_groups_board | Group retrieval by board |
| idx_board_groups_sort | Ordered group listing |
| idx_board_items_board | Item retrieval by board |
| idx_board_items_group | Items within a group (denormalized group view) |
| idx_board_items_resource | Finding items by K8s resource |
| idx_board_items_cluster_resource | Cluster-scoped resource lookup |
| idx_board_items_assigned | User assignment queries |
| idx_board_items_sort | Ordered item listing |
| idx_column_values_item | All values for an item |
| idx_column_values_column | All items' values for a column |

## Redis Caching

The board views benefit from Redis caching for:
1. **Board layout** (structure + columns) - cached by board_id
2. **Item list per group** - cached with pagination token
3. **Column value aggregations** - cached sorted sets for status counts

## Migration Sequence

- **009**: `board_columns` table (BOARD-02)
- **012**: This migration (BOARD-01) - boards, groups, items, column values


# Migration README — BOARD-01 (Migration 012)

## Purpose

Implements the core board view schema for a monday.com-style Kubernetes resource board. This migration establishes the persistence model for boards, groups, items, and column values.

## Migration Files

| File | Purpose |
|------|---------|
| `012_board_01_board_view.up.sql` | Creates tables: boards, board_groups, board_items, board_item_column_values + supplements board_columns |
| `012_board_01_board_view.down.sql` | Drops all BOARD-01 tables and reverts supplemental changes |

## Dependencies

- **Must run after**: `009_board_02_board_columns` (provides board_columns table)
- **Must run after**: Initial schema with `users` and `workspaces` tables (if they exist, FKs are added conditionally)

## Run Order

```bash
# Apply
goose -dir docs/migrations up

# Or target specific version
goose -dir docs/migrations up-to 12

# Rollback
goose -dir docs/migrations down
```

## Verification

After applying, verify with:

```sql
-- Check tables exist
SELECT table_name FROM information_schema.tables 
WHERE table_name IN ('boards','board_groups','board_items','board_item_column_values');

-- Check board_columns supplements
SELECT column_name FROM information_schema.columns 
WHERE table_name = 'board_columns' 
  AND column_name IN ('settings','width','is_archived');

-- Check indexes exist
SELECT indexname FROM pg_indexes 
WHERE tablename IN ('boards','board_groups','board_items','board_item_column_values');

-- Check seed data
SELECT b.name, COUNT(bi.id) as item_count
FROM boards b
LEFT JOIN board_items bi ON bi.board_id = b.id
GROUP BY b.id, b.name;
```

## Schema Design Decisions

### 1. Polymorphic Column Values
Instead of separate tables per column type (text_values, status_values, etc.), we use a single `board_item_column_values` table with typed columns (value, numeric_value, date_value, person_value, status_value). This simplifies queries while still allowing type-specific sorting and indexing.

### 2. Denormalized Resource Fields
`board_items` includes `resource_name`, `resource_namespace`, and `cluster_id` directly (denormalized from the K8s resource). This avoids joins for the most common display operations while maintaining the FK-style `resource_id` + `resource_type` for proper relationships.

### 3. Conditional Foreign Keys
Foreign keys to `users`, `workspaces`, and `clusters` tables are added via DO blocks that check table existence first. This allows the migration to work regardless of the exact order of schema initialization.

### 4. JSONB Filter Config
The `boards.filter_config` column stores flexible filter criteria (cluster, namespace, resource type, label selectors) as JSONB, allowing the board view to be dynamically scoped without schema changes.

### 5. Soft Deletes
All entities use `is_archived` boolean flags rather than hard deletes, enabling undo functionality and audit trails.
