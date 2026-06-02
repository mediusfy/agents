

# RESOURCE-01: Deployment Board Database Schema

## Domain Overview

The Deployment Board provides operations engineers with a kanban-style visualization of all Deployments within a selected cluster and namespace. Each board is scoped to exactly one cluster + namespace combination and organizes deployments into columns based on their health/operational status.

### Entity-Relationship Diagram (text)

```
[clusters] 1───* [namespaces]
   |                    |
   |                    |
   └───* [deployment_boards] *────┘
              |
              ├──1──* [deployment_board_columns]
              |
              └──1──* [deployment_board_cards] *──1── [deployments]
                                |
                                └──* [deployment_status_events]
```

### Enum: `deployment_status`

| Value | Meaning |
|-------|---------|
| `Running` | All desired replicas are available and healthy |
| `Pending` | Waiting for scheduling, image pull, or volumes |
| `Failed` | CrashLoopBackOff, Error, or OOMKilled state |
| `ScalingUp` | Replicas being increased (rollout or scaling) |
| `ScalingDown` | Replicas being decreased |
| `Unknown` | Status could not be determined |
| `Paused` | Rollout paused (kubectl rollout pause) |
| `Progressing` | Rollout in progress, not yet complete |

### Table: `deployment_boards`

Stores board configurations scoped to a cluster + namespace.

| Column | Type | Constraints | Description |
|--------|------|------------|-------------|
| id | `UUID` | PK, DEFAULT gen_random_uuid() | Unique identifier |
| name | `VARCHAR(255)` | NOT NULL | Board display name |
| description | `TEXT` | | Optional description |
| cluster_id | `UUID` | NOT NULL, FK → clusters(id) | Target cluster |
| namespace | `VARCHAR(253)` | NOT NULL | Target namespace (DNS label) |
| layout_config | `JSONB` | DEFAULT '{}' | Column widths, ordering, theme settings |
| is_default | `BOOLEAN` | NOT NULL DEFAULT false | Whether this is the default board for the cluster+namespace |
| is_auto_populated | `BOOLEAN` | NOT NULL DEFAULT true | Whether deployments auto-place into columns by status |
| created_at | `TIMESTAMPTZ` | NOT NULL DEFAULT NOW() | Creation timestamp |
| updated_at | `TIMESTAMPTZ` | NOT NULL DEFAULT NOW() | Last update timestamp |

**Uniques:** UNIQUE(cluster_id, namespace, name)

### Table: `deployment_board_columns`

Columns within a board, representing deployment status lanes.

| Column | Type | Constraints | Description |
|--------|------|------------|-------------|
| id | `UUID` | PK, DEFAULT gen_random_uuid() | Unique identifier |
| board_id | `UUID` | NOT NULL, FK → deployment_boards(id) ON DELETE CASCADE | Parent board |
| name | `VARCHAR(100)` | NOT NULL | Column display name (e.g., "Running", "Pending") |
| status_filter | `deployment_status[]` | NOT NULL DEFAULT '{}' | Which statuses belong in this column |
| wip_limit | `INTEGER` | CHECK(wip_limit > 0) | Optional work-in-progress limit |
| position | `INTEGER` | NOT NULL | Display order (0-based) |
| color | `VARCHAR(7)` | CHECK(color ~ '^#[0-9A-Fa-f]{6}$') | Hex color for the column header |
| is_collapsible | `BOOLEAN` | NOT NULL DEFAULT true | Whether users can collapse this column |
| created_at | `TIMESTAMPTZ` | NOT NULL DEFAULT NOW() | Creation timestamp |
| updated_at | `TIMESTAMPTZ` | NOT NULL DEFAULT NOW() | Last update timestamp |

**Uniques:** UNIQUE(board_id, name), UNIQUE(board_id, position)

### Table: `deployment_board_cards`

Links deployments to their board column positions.

| Column | Type | Constraints | Description |
|--------|------|------------|-------------|
| id | `UUID` | PK, DEFAULT gen_random_uuid() | Unique identifier |
| board_id | `UUID` | NOT NULL, FK → deployment_boards(id) ON DELETE CASCADE | Parent board |
| column_id | `UUID` | NOT NULL, FK → deployment_board_columns(id) ON DELETE CASCADE | Column placement |
| deployment_id | `UUID` | NOT NULL, FK → deployments(id) ON DELETE CASCADE | The deployment |
| position | `INTEGER` | NOT NULL DEFAULT 0 | Sort order within column |
| custom_label | `VARCHAR(255)` | | User-overridden label on the card |
| is_pinned | `BOOLEAN` | NOT NULL DEFAULT false | Whether card is pinned to this position |
| notes | `TEXT` | | Operator notes about this deployment |
| created_at | `TIMESTAMPTZ` | NOT NULL DEFAULT NOW() | Creation timestamp |
| updated_at | `TIMESTAMPTZ` | NOT NULL DEFAULT NOW() | Last update timestamp |

**Uniques:** UNIQUE(board_id, deployment_id), UNIQUE(column_id, position)

### Table: `deployment_status_events`

Immutable audit trail for deployment status transitions.

| Column | Type | Constraints | Description |
|--------|------|------------|-------------|
| id | `UUID` | PK, DEFAULT gen_random_uuid() | Unique identifier |
| deployment_id | `UUID` | NOT NULL, FK → deployments(id) ON DELETE CASCADE | The deployment |
| previous_status | `deployment_status` | | The previous status (NULL on first event) |
| new_status | `deployment_status` | NOT NULL | The new status |
| reason | `VARCHAR(255)` | | Reason for transition (e.g., "CrashLoopBackOff") |
| message | `TEXT` | | Detailed message from Kubernetes |
| source | `VARCHAR(50)` | NOT NULL DEFAULT 'system' | 'system', 'user', 'webhook' |
| observed_at | `TIMESTAMPTZ` | NOT NULL DEFAULT NOW() | When the status was observed |
| created_at | `TIMESTAMPTZ` | NOT NULL DEFAULT NOW() | Record creation timestamp |

### Materialized View: `mv_deployment_board_snapshot`

Provides a denormalized, pre-joined view optimized for board rendering.

```sql
SELECT
    db.id AS board_id,
    db.name AS board_name,
    db.namespace,
    c.name AS cluster_name,
    dbc.id AS column_id,
    dbc.name AS column_name,
    dbc.color AS column_color,
    dbc.position AS column_position,
    d.id AS deployment_id,
    d.name AS deployment_name,
    d.status,
    d.desired_replicas,
    d.available_replicas,
    d.ready_replicas,
    d.labels,
    dbc2.position AS card_position,
    dbc2.is_pinned,
    d.created_at AS deployment_created_at,
    d.updated_at AS deployment_updated_at
FROM deployment_boards db
JOIN clusters c ON c.id = db.cluster_id
JOIN deployment_board_columns dbc ON dbc.board_id = db.id
LEFT JOIN deployment_board_cards dbc2 
    ON dbc2.board_id = db.id AND dbc2.column_id = dbc.id
LEFT JOIN deployments d ON d.id = dbc2.deployment_id
WHERE dbc2.id IS NOT NULL;
```

## Indexing Strategy

| Index Name | Type | Table | Columns | Purpose |
|-----------|------|-------|---------|---------|
| idx_dep_boards_cluster_namespace | BTREE | deployment_boards | (cluster_id, namespace) | Board lookup by scope |
| idx_dep_boards_default | BTREE | deployment_boards | (cluster_id, is_default) | Find default board |
| idx_dep_columns_board_position | BTREE | deployment_board_columns | (board_id, position) | Column ordering |
| idx_dep_cards_board_column_position | BTREE | deployment_board_cards | (board_id, column_id, position) | Card ordering |
| idx_dep_cards_deployment | BTREE | deployment_board_cards | (deployment_id) | Card lookup by deployment |
| idx_dep_status_events_deployment_time | BTREE | deployment_status_events | (deployment_id, observed_at DESC) | Status timeline |
| idx_dep_status_events_new_status | BTREE | deployment_status_events | (new_status) | Filter by status |
| idx_dep_boards_layout | GIN | deployment_boards | layout_config | JSONB querying |
| idx_dep_status_events_created | BRIN | deployment_status_events | created_at | Time-range scans |
