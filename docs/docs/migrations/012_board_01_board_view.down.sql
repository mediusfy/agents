

-- Migration: 012_board_01_board_view
-- Description: Rollback the monday.com-Style Board View schema

-- +goose Down
-- +goose StatementBegin

-- Drop foreign key constraints (optional, cascades handle these)
ALTER TABLE IF EXISTS board_items DROP CONSTRAINT IF EXISTS fk_board_items_cluster;
ALTER TABLE IF EXISTS board_items DROP CONSTRAINT IF EXISTS fk_board_items_created_by;
ALTER TABLE IF EXISTS board_items DROP CONSTRAINT IF EXISTS fk_board_items_assigned_to;
ALTER TABLE IF EXISTS board_item_column_values DROP CONSTRAINT IF EXISTS fk_board_item_column_values_person;
ALTER TABLE IF EXISTS boards DROP CONSTRAINT IF EXISTS fk_boards_workspace;
ALTER TABLE IF EXISTS boards DROP CONSTRAINT IF EXISTS fk_boards_owner;

-- Drop triggers
DROP TRIGGER IF EXISTS update_board_item_column_values_modtime ON board_item_column_values;
DROP TRIGGER IF EXISTS update_board_items_modtime ON board_items;
DROP TRIGGER IF EXISTS update_board_groups_modtime ON board_groups;
DROP TRIGGER IF EXISTS update_boards_modtime ON boards;

-- Drop tables (order respects FK dependencies)
DROP TABLE IF EXISTS board_item_column_values;
DROP TABLE IF EXISTS board_items;
DROP TABLE IF EXISTS board_groups;
DROP TABLE IF EXISTS boards;

-- Drop supplemental columns from board_columns (if we added them)
DO $$ BEGIN
    IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'board_columns') THEN
        IF EXISTS (SELECT FROM information_schema.columns 
                   WHERE table_name = 'board_columns' AND column_name = 'settings') THEN
            ALTER TABLE board_columns DROP COLUMN IF EXISTS settings;
        END IF;
        IF EXISTS (SELECT FROM information_schema.columns 
                   WHERE table_name = 'board_columns' AND column_name = 'width') THEN
            ALTER TABLE board_columns DROP COLUMN IF EXISTS width;
        END IF;
        IF EXISTS (SELECT FROM information_schema.columns 
                   WHERE table_name = 'board_columns' AND column_name = 'is_archived') THEN
            ALTER TABLE board_columns DROP COLUMN IF EXISTS is_archived;
        END IF;
    END IF;
END $$;

-- Drop custom types (only if they are no longer used)
DO $$ BEGIN
    DROP TYPE IF EXISTS board_column_type;
EXCEPTION
    WHEN dependent_objects THEN NULL;
END $$;

DO $$ BEGIN
    DROP TYPE IF EXISTS board_kind;
EXCEPTION
    WHEN dependent_objects THEN NULL;
END $$;

-- +goose StatementEnd


-- +goose Down
-- +goose StatementBegin

-- Drop foreign key constraints
ALTER TABLE IF EXISTS board_items DROP CONSTRAINT IF EXISTS fk_board_items_cluster;
ALTER TABLE IF EXISTS board_items DROP CONSTRAINT IF EXISTS fk_board_items_created_by;
ALTER TABLE IF EXISTS board_items DROP CONSTRAINT IF EXISTS fk_board_items_assigned_to;
ALTER TABLE IF EXISTS board_item_column_values DROP CONSTRAINT IF EXISTS fk_board_item_column_values_person;
ALTER TABLE IF EXISTS boards DROP CONSTRAINT IF EXISTS fk_boards_workspace;
ALTER TABLE IF EXISTS boards DROP CONSTRAINT IF EXISTS fk_boards_owner;

-- Drop triggers
DROP TRIGGER IF EXISTS update_board_item_column_values_modtime ON board_item_column_values;
DROP TRIGGER IF EXISTS update_board_items_modtime ON board_items;
DROP TRIGGER IF EXISTS update_board_groups_modtime ON board_groups;
DROP TRIGGER IF EXISTS update_boards_modtime ON boards;

-- Drop tables (order respects FK dependencies)
DROP TABLE IF EXISTS board_item_column_values;
DROP TABLE IF EXISTS board_items;
DROP TABLE IF EXISTS board_groups;
DROP TABLE IF EXISTS boards;

-- Drop supplemental columns from board_columns (added by this migration)
DO $$ BEGIN
    IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'board_columns') THEN
        IF EXISTS (SELECT FROM information_schema.columns 
                   WHERE table_name = 'board_columns' AND column_name = 'settings') THEN
            ALTER TABLE board_columns DROP COLUMN IF EXISTS settings;
        END IF;
        IF EXISTS (SELECT FROM information_schema.columns 
                   WHERE table_name = 'board_columns' AND column_name = 'width') THEN
            ALTER TABLE board_columns DROP COLUMN IF EXISTS width;
        END IF;
        IF EXISTS (SELECT FROM information_schema.columns 
                   WHERE table_name = 'board_columns' AND column_name = 'is_archived') THEN
            ALTER TABLE board_columns DROP COLUMN IF EXISTS is_archived;
        END IF;
    END IF;
END $$;

-- Drop indexes that were added to board_columns
DROP INDEX IF EXISTS idx_board_columns_board;
DROP INDEX IF EXISTS idx_board_columns_sort;

-- +goose StatementEnd
