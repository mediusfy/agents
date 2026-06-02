

-- Migration: 012_board_01_board_view
-- Description: monday.com-Style Board View for Kubernetes Resources
-- Depends: 009_board_02_board_columns (board_columns table)
-- 
-- Creates the core board view schema including:
--   - boards: Top-level board definitions
--   - board_groups: Horizontal groups/lanes within boards
--   - board_items: Individual items representing K8s resources
--   - board_item_column_values: Polymorphic column value storage

-- +goose Up
-- +goose StatementBegin

-- =============================================================================
-- ENUM TYPES
-- =============================================================================

DO $$ BEGIN
    CREATE TYPE board_kind AS ENUM (
        'main',
        'private',
        'shared',
        'template'
    );
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE board_column_type AS ENUM (
        'text',
        'status',
        'date',
        'numeric',
        'person',
        'timeline',
        'color',
        'link',
        'rating',
        'long_text',
        'email',
        'phone',
        'country',
        'tags',
        'progress',
        'hour',
        'formula',
        'dependency'
    );
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- =============================================================================
-- UPDATED_AT TRIGGER FUNCTION
-- =============================================================================

CREATE OR REPLACE FUNCTION update_modified_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

-- =============================================================================
-- BOARDS
-- =============================================================================

CREATE TABLE IF NOT EXISTS boards (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            VARCHAR(255) NOT NULL,
    description     TEXT,
    board_kind      VARCHAR(50) NOT NULL DEFAULT 'main',
    workspace_id    UUID,
    owner_id        UUID,
    filter_config   JSONB DEFAULT '{}'::jsonb,
    sort_order      INTEGER NOT NULL DEFAULT 0,
    is_archived     BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER update_boards_modtime
    BEFORE UPDATE ON boards
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

CREATE INDEX IF NOT EXISTS idx_boards_workspace     ON boards(workspace_id) WHERE workspace_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_boards_owner         ON boards(owner_id) WHERE owner_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_boards_sort          ON boards(sort_order);
CREATE INDEX IF NOT EXISTS idx_boards_active        ON boards(id) WHERE is_archived = FALSE;
CREATE INDEX IF NOT EXISTS idx_boards_created_at    ON boards(created_at);

COMMENT ON TABLE  boards            IS 'Top-level board definitions for the monday.com-style board view of Kubernetes resources';
COMMENT ON COLUMN boards.name       IS 'Display name of the board';
COMMENT ON COLUMN boards.board_kind IS 'Board type: main, private, shared, template';
COMMENT ON COLUMN boards.filter_config IS 'JSONB filter criteria for K8s resources (cluster, namespace, resource type, labels)';

-- =============================================================================
-- BOARD GROUPS (Horizontal swimlanes)
-- =============================================================================

CREATE TABLE IF NOT EXISTS board_groups (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    board_id        UUID NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
    title           VARCHAR(255) NOT NULL,
    color           VARCHAR(50),
    icon            VARCHAR(50),
    sort_order      INTEGER NOT NULL DEFAULT 0,
    is_archived     BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER update_board_groups_modtime
    BEFORE UPDATE ON board_groups
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

CREATE INDEX IF NOT EXISTS idx_board_groups_board    ON board_groups(board_id);
CREATE INDEX IF NOT EXISTS idx_board_groups_sort     ON board_groups(board_id, sort_order);
CREATE INDEX IF NOT EXISTS idx_board_groups_active   ON board_groups(id) WHERE is_archived = FALSE;

COMMENT ON TABLE  board_groups           IS 'Horizontal groups/lanes within a board (like swimlanes in monday.com)';
COMMENT ON COLUMN board_groups.color     IS 'Accent color for the group header';

-- =============================================================================
-- BOARD COLUMNS (Supplement to 009 migration - adds settings/width if needed)
-- Note: The base board_columns table was created in migration 009.
-- This migration adds supplemental columns to enhance the data model.
-- =============================================================================

-- Check if board_columns exists and add columns if not present
DO $$ BEGIN
    IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'board_columns') THEN
        -- Add settings JSONB column if it doesn't exist
        IF NOT EXISTS (SELECT FROM information_schema.columns 
                       WHERE table_name = 'board_columns' AND column_name = 'settings') THEN
            ALTER TABLE board_columns ADD COLUMN settings JSONB DEFAULT '{}'::jsonb;
        END IF;
        -- Add width column if it doesn't exist
        IF NOT EXISTS (SELECT FROM information_schema.columns 
                       WHERE table_name = 'board_columns' AND column_name = 'width') THEN
            ALTER TABLE board_columns ADD COLUMN width INTEGER NOT NULL DEFAULT 200;
        END IF;
        -- Add is_archived column if it doesn't exist
        IF NOT EXISTS (SELECT FROM information_schema.columns 
                       WHERE table_name = 'board_columns' AND column_name = 'is_archived') THEN
            ALTER TABLE board_columns ADD COLUMN is_archived BOOLEAN NOT NULL DEFAULT FALSE;
        END IF;
    END IF;
END $$;

-- Ensure indexes exist on board_columns
CREATE INDEX IF NOT EXISTS idx_board_columns_board   ON board_columns(board_id);
CREATE INDEX IF NOT EXISTS idx_board_columns_sort    ON board_columns(board_id, sort_order);

-- =============================================================================
-- BOARD ITEMS (Individual items/rows)
-- =============================================================================

CREATE TABLE IF NOT EXISTS board_items (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    board_id            UUID NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
    group_id            UUID REFERENCES board_groups(id) ON DELETE SET NULL,
    title               VARCHAR(500) NOT NULL,
    description         TEXT,
    resource_id         UUID,
    resource_type       VARCHAR(100),
    resource_name       VARCHAR(253),
    resource_namespace  VARCHAR(253),
    cluster_id          UUID,
    icon                VARCHAR(50),
    color               VARCHAR(50),
    sort_order          INTEGER NOT NULL DEFAULT 0,
    is_archived         BOOLEAN NOT NULL DEFAULT FALSE,
    created_by          UUID,
    assigned_to         UUID,
    due_date            TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER update_board_items_modtime
    BEFORE UPDATE ON board_items
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

CREATE INDEX IF NOT EXISTS idx_board_items_board         ON board_items(board_id);
CREATE INDEX IF NOT EXISTS idx_board_items_group         ON board_items(group_id);
CREATE INDEX IF NOT EXISTS idx_board_items_resource      ON board_items(resource_id, resource_type) WHERE resource_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_board_items_cluster_ns    ON board_items(cluster_id, resource_namespace) WHERE cluster_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_board_items_assigned      ON board_items(assigned_to) WHERE assigned_to IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_board_items_sort          ON board_items(board_id, group_id, sort_order);
CREATE INDEX IF NOT EXISTS idx_board_items_active        ON board_items(id) WHERE is_archived = FALSE;
CREATE INDEX IF NOT EXISTS idx_board_items_due_date      ON board_items(due_date) WHERE due_date IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_board_items_created_at    ON board_items(created_at);

COMMENT ON TABLE  board_items                  IS 'Individual items/rows representing Kubernetes resources or tasks';
COMMENT ON COLUMN board_items.resource_id      IS 'FK to the specific K8s resource (polymorphic, combined with resource_type)';
COMMENT ON COLUMN board_items.resource_type    IS 'K8s resource type: pod, deployment, service, ingress, configmap, etc.';
COMMENT ON COLUMN board_items.resource_name    IS 'Denormalized K8s resource name for quick display';
COMMENT ON COLUMN board_items.resource_namespace IS 'Denormalized K8s namespace';
COMMENT ON COLUMN board_items.cluster_id       IS 'Source cluster for the resource';

-- =============================================================================
-- BOARD ITEM COLUMN VALUES (Polymorphic column value storage)
-- =============================================================================

CREATE TABLE IF NOT EXISTS board_item_column_values (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    item_id         UUID NOT NULL REFERENCES board_items(id) ON DELETE CASCADE,
    column_id       UUID NOT NULL REFERENCES board_columns(id) ON DELETE CASCADE,
    value           TEXT,
    numeric_value   NUMERIC,
    date_value      TIMESTAMPTZ,
    person_value    UUID,
    status_value    VARCHAR(100),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_item_column UNIQUE (item_id, column_id)
);

CREATE TRIGGER update_board_item_column_values_modtime
    BEFORE UPDATE ON board_item_column_values
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

CREATE INDEX IF NOT EXISTS idx_colval_item     ON board_item_column_values(item_id);
CREATE INDEX IF NOT EXISTS idx_colval_column   ON board_item_column_values(column_id);
CREATE INDEX IF NOT EXISTS idx_colval_numeric  ON board_item_column_values(column_id, numeric_value) WHERE numeric_value IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_colval_status   ON board_item_column_values(column_id, status_value) WHERE status_value IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_colval_date     ON board_item_column_values(column_id, date_value) WHERE date_value IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_colval_person   ON board_item_column_values(column_id, person_value) WHERE person_value IS NOT NULL;

COMMENT ON TABLE  board_item_column_values            IS 'Polymorphic column value storage for board items';
COMMENT ON COLUMN board_item_column_values.value      IS 'Raw/serialized value (type-specific fallback)';
COMMENT ON COLUMN board_item_column_values.numeric_value IS 'Numeric value for sorting/computation on numeric columns';
COMMENT ON COLUMN board_item_column_values.date_value IS 'Date value for date/timeline columns';
COMMENT ON COLUMN board_item_column_values.person_value IS 'User UUID reference for person columns';
COMMENT ON COLUMN board_item_column_values.status_value IS 'Status index/label for status columns';

-- =============================================================================
-- FOREIGN KEY CONSTRAINTS (deferred for circular reference safety)
-- =============================================================================

-- Add FK from board_items to clusters if clusters table exists
DO $$ BEGIN
    IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'clusters') THEN
        IF NOT EXISTS (SELECT FROM information_schema.table_constraints 
                       WHERE constraint_name = 'fk_board_items_cluster') THEN
            ALTER TABLE board_items
                ADD CONSTRAINT fk_board_items_cluster
                FOREIGN KEY (cluster_id) REFERENCES clusters(id) ON DELETE SET NULL;
        END IF;
    END IF;
END $$;

-- Add FK from board_items to users for created_by if users table exists
DO $$ BEGIN
    IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'users') THEN
        IF NOT EXISTS (SELECT FROM information_schema.table_constraints 
                       WHERE constraint_name = 'fk_board_items_created_by') THEN
            ALTER TABLE board_items
                ADD CONSTRAINT fk_board_items_created_by
                FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
        END IF;
        IF NOT EXISTS (SELECT FROM information_schema.table_constraints 
                       WHERE constraint_name = 'fk_board_items_assigned_to') THEN
            ALTER TABLE board_items
                ADD CONSTRAINT fk_board_items_assigned_to
                FOREIGN KEY (assigned_to) REFERENCES users(id) ON DELETE SET NULL;
        END IF;
        IF NOT EXISTS (SELECT FROM information_schema.table_constraints 
                       WHERE constraint_name = 'fk_board_item_column_values_person') THEN
            ALTER TABLE board_item_column_values
                ADD CONSTRAINT fk_board_item_column_values_person
                FOREIGN KEY (person_value) REFERENCES users(id) ON DELETE SET NULL;
        END IF;
    END IF;
END $$;

-- Add FK from boards to workspaces if workspaces table exists
DO $$ BEGIN
    IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'workspaces') THEN
        IF NOT EXISTS (SELECT FROM information_schema.table_constraints 
                       WHERE constraint_name = 'fk_boards_workspace') THEN
            ALTER TABLE boards
                ADD CONSTRAINT fk_boards_workspace
                FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE;
        END IF;
    END IF;
END $$;

-- Add FK from boards to users for owner if users table exists
DO $$ BEGIN
    IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'users') THEN
        IF NOT EXISTS (SELECT FROM information_schema.table_constraints 
                       WHERE constraint_name = 'fk_boards_owner') THEN
            ALTER TABLE boards
                ADD CONSTRAINT fk_boards_owner
                FOREIGN KEY (owner_id) REFERENCES users(id) ON DELETE SET NULL;
        END IF;
    END IF;
END $$;

-- +goose StatementEnd


-- +goose Up
-- +goose StatementBegin

-- =============================================================================
-- UPDATED_AT TRIGGER FUNCTION
-- =============================================================================
CREATE OR REPLACE FUNCTION update_modified_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

-- =============================================================================
-- BOARDS
-- =============================================================================
CREATE TABLE IF NOT EXISTS boards (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            VARCHAR(255) NOT NULL,
    description     TEXT,
    board_kind      VARCHAR(50) NOT NULL DEFAULT 'main',
    workspace_id    UUID,
    owner_id        UUID,
    filter_config   JSONB DEFAULT '{}'::jsonb,
    sort_order      INTEGER NOT NULL DEFAULT 0,
    is_archived     BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER update_boards_modtime
    BEFORE UPDATE ON boards
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

CREATE INDEX IF NOT EXISTS idx_boards_workspace     ON boards(workspace_id) WHERE workspace_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_boards_owner         ON boards(owner_id) WHERE owner_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_boards_sort          ON boards(sort_order);
CREATE INDEX IF NOT EXISTS idx_boards_active        ON boards(id) WHERE is_archived = FALSE;
CREATE INDEX IF NOT EXISTS idx_boards_created_at    ON boards(created_at);

COMMENT ON TABLE  boards            IS 'Top-level board definitions for the monday.com-style board view of Kubernetes resources';
COMMENT ON COLUMN boards.name       IS 'Display name of the board';
COMMENT ON COLUMN boards.board_kind IS 'Board type: main, private, shared, template';
COMMENT ON COLUMN boards.filter_config IS 'JSONB filter criteria for K8s resources (cluster, namespace, resource type, labels)';

-- =============================================================================
-- BOARD GROUPS (Horizontal swimlanes)
-- =============================================================================
CREATE TABLE IF NOT EXISTS board_groups (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    board_id        UUID NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
    title           VARCHAR(255) NOT NULL,
    color           VARCHAR(50),
    icon            VARCHAR(50),
    sort_order      INTEGER NOT NULL DEFAULT 0,
    is_archived     BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER update_board_groups_modtime
    BEFORE UPDATE ON board_groups
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

CREATE INDEX IF NOT EXISTS idx_board_groups_board    ON board_groups(board_id);
CREATE INDEX IF NOT EXISTS idx_board_groups_sort     ON board_groups(board_id, sort_order);
CREATE INDEX IF NOT EXISTS idx_board_groups_active   ON board_groups(id) WHERE is_archived = FALSE;

COMMENT ON TABLE  board_groups           IS 'Horizontal groups/lanes within a board (like swimlanes in monday.com)';
COMMENT ON COLUMN board_groups.color     IS 'Accent color for the group header';

-- =============================================================================
-- SUPPLEMENT BOARD COLUMNS (from 009 migration)
-- =============================================================================
DO $$ BEGIN
    IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'board_columns') THEN
        IF NOT EXISTS (SELECT FROM information_schema.columns 
                       WHERE table_name = 'board_columns' AND column_name = 'settings') THEN
            ALTER TABLE board_columns ADD COLUMN settings JSONB DEFAULT '{}'::jsonb;
        END IF;
        IF NOT EXISTS (SELECT FROM information_schema.columns 
                       WHERE table_name = 'board_columns' AND column_name = 'width') THEN
            ALTER TABLE board_columns ADD COLUMN width INTEGER NOT NULL DEFAULT 200;
        END IF;
        IF NOT EXISTS (SELECT FROM information_schema.columns 
                       WHERE table_name = 'board_columns' AND column_name = 'is_archived') THEN
            ALTER TABLE board_columns ADD COLUMN is_archived BOOLEAN NOT NULL DEFAULT FALSE;
        END IF;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_board_columns_board   ON board_columns(board_id);
CREATE INDEX IF NOT EXISTS idx_board_columns_sort    ON board_columns(board_id, sort_order);

-- =============================================================================
-- BOARD ITEMS (Individual items/rows)
-- =============================================================================
CREATE TABLE IF NOT EXISTS board_items (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    board_id            UUID NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
    group_id            UUID REFERENCES board_groups(id) ON DELETE SET NULL,
    title               VARCHAR(500) NOT NULL,
    description         TEXT,
    resource_id         UUID,
    resource_type       VARCHAR(100),
    resource_name       VARCHAR(253),
    resource_namespace  VARCHAR(253),
    cluster_id          UUID,
    icon                VARCHAR(50),
    color               VARCHAR(50),
    sort_order          INTEGER NOT NULL DEFAULT 0,
    is_archived         BOOLEAN NOT NULL DEFAULT FALSE,
    created_by          UUID,
    assigned_to         UUID,
    due_date            TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER update_board_items_modtime
    BEFORE UPDATE ON board_items
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

CREATE INDEX IF NOT EXISTS idx_board_items_board         ON board_items(board_id);
CREATE INDEX IF NOT EXISTS idx_board_items_group         ON board_items(group_id);
CREATE INDEX IF NOT EXISTS idx_board_items_resource      ON board_items(resource_id, resource_type) WHERE resource_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_board_items_cluster_ns    ON board_items(cluster_id, resource_namespace) WHERE cluster_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_board_items_assigned      ON board_items(assigned_to) WHERE assigned_to IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_board_items_sort          ON board_items(board_id, group_id, sort_order);
CREATE INDEX IF NOT EXISTS idx_board_items_active        ON board_items(id) WHERE is_archived = FALSE;
CREATE INDEX IF NOT EXISTS idx_board_items_due_date      ON board_items(due_date) WHERE due_date IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_board_items_created_at    ON board_items(created_at);

COMMENT ON TABLE  board_items                  IS 'Individual items/rows representing Kubernetes resources or tasks';
COMMENT ON COLUMN board_items.resource_id      IS 'FK to the specific K8s resource (polymorphic, combined with resource_type)';
COMMENT ON COLUMN board_items.resource_type    IS 'K8s resource type: pod, deployment, service, ingress, configmap, etc.';
COMMENT ON COLUMN board_items.resource_name    IS 'Denormalized K8s resource name for quick display';
COMMENT ON COLUMN board_items.resource_namespace IS 'Denormalized K8s namespace';
COMMENT ON COLUMN board_items.cluster_id       IS 'Source cluster for the resource';

-- =============================================================================
-- BOARD ITEM COLUMN VALUES
-- =============================================================================
CREATE TABLE IF NOT EXISTS board_item_column_values (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    item_id         UUID NOT NULL REFERENCES board_items(id) ON DELETE CASCADE,
    column_id       UUID NOT NULL REFERENCES board_columns(id) ON DELETE CASCADE,
    value           TEXT,
    numeric_value   NUMERIC,
    date_value      TIMESTAMPTZ,
    person_value    UUID,
    status_value    VARCHAR(100),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_item_column UNIQUE (item_id, column_id)
);

CREATE TRIGGER update_board_item_column_values_modtime
    BEFORE UPDATE ON board_item_column_values
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

CREATE INDEX IF NOT EXISTS idx_colval_item     ON board_item_column_values(item_id);
CREATE INDEX IF NOT EXISTS idx_colval_column   ON board_item_column_values(column_id);
CREATE INDEX IF NOT EXISTS idx_colval_numeric  ON board_item_column_values(column_id, numeric_value) WHERE numeric_value IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_colval_status   ON board_item_column_values(column_id, status_value) WHERE status_value IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_colval_date     ON board_item_column_values(column_id, date_value) WHERE date_value IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_colval_person   ON board_item_column_values(column_id, person_value) WHERE person_value IS NOT NULL;

COMMENT ON TABLE  board_item_column_values            IS 'Polymorphic column value storage for board items';
COMMENT ON COLUMN board_item_column_values.value      IS 'Raw/serialized value (type-specific fallback)';
COMMENT ON COLUMN board_item_column_values.numeric_value IS 'Numeric value for sorting/computation on numeric columns';
COMMENT ON COLUMN board_item_column_values.date_value IS 'Date value for date/timeline columns';
COMMENT ON COLUMN board_item_column_values.person_value IS 'User UUID reference for person columns';
COMMENT ON COLUMN board_item_column_values.status_value IS 'Status index/label for status columns';

-- =============================================================================
-- CONDITIONAL FOREIGN KEYS
-- =============================================================================
DO $$ BEGIN
    IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'clusters') THEN
        IF NOT EXISTS (SELECT FROM information_schema.table_constraints 
                       WHERE constraint_name = 'fk_board_items_cluster') THEN
            ALTER TABLE board_items
                ADD CONSTRAINT fk_board_items_cluster
                FOREIGN KEY (cluster_id) REFERENCES clusters(id) ON DELETE SET NULL;
        END IF;
    END IF;
END $$;

DO $$ BEGIN
    IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'users') THEN
        IF NOT EXISTS (SELECT FROM information_schema.table_constraints 
                       WHERE constraint_name = 'fk_board_items_created_by') THEN
            ALTER TABLE board_items
                ADD CONSTRAINT fk_board_items_created_by
                FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
        END IF;
        IF NOT EXISTS (SELECT FROM information_schema.table_constraints 
                       WHERE constraint_name = 'fk_board_items_assigned_to') THEN
            ALTER TABLE board_items
                ADD CONSTRAINT fk_board_items_assigned_to
                FOREIGN KEY (assigned_to) REFERENCES users(id) ON DELETE SET NULL;
        END IF;
        IF NOT EXISTS (SELECT FROM information_schema.table_constraints 
                       WHERE constraint_name = 'fk_board_item_column_values_person') THEN
            ALTER TABLE board_item_column_values
                ADD CONSTRAINT fk_board_item_column_values_person
                FOREIGN KEY (person_value) REFERENCES users(id) ON DELETE SET NULL;
        END IF;
        IF NOT EXISTS (SELECT FROM information_schema.table_constraints 
                       WHERE constraint_name = 'fk_boards_owner') THEN
            ALTER TABLE boards
                ADD CONSTRAINT fk_boards_owner
                FOREIGN KEY (owner_id) REFERENCES users(id) ON DELETE SET NULL;
        END IF;
    END IF;
END $$;

DO $$ BEGIN
    IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'workspaces') THEN
        IF NOT EXISTS (SELECT FROM information_schema.table_constraints 
                       WHERE constraint_name = 'fk_boards_workspace') THEN
            ALTER TABLE boards
                ADD CONSTRAINT fk_boards_workspace
                FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE;
        END IF;
    END IF;
END $$;

-- +goose StatementEnd
