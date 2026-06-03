-- Migration: ENTITYMGMT-01_000_schema_definition.down.sql
-- Story: ENTITYMGMT-01 — Rollback schema definition tables and functions
-- Bounded Context: Entity Management
--
-- Reverses ENTITYMGMT-01_000_schema_definition.up.sql
--
-- Ordered rollback:
--   1. Drop functions (depend on tables but no inter-function dependencies)
--   2. Drop triggers on entity_schemas
--   3. Drop tables (entity_schema_attributes first due to FK)
--   4. Drop ENUM type
--   5. Drop helper function (no dependencies after tables are gone)
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. Drop functions (in reverse dependency order)
-- ============================================================================

-- Schema query/validation functions
DROP FUNCTION IF EXISTS count_schema_attributes(UUID);
DROP FUNCTION IF EXISTS schema_exists(VARCHAR);
DROP FUNCTION IF EXISTS list_all_schemas();
DROP FUNCTION IF EXISTS find_schema_by_name(VARCHAR);
DROP FUNCTION IF EXISTS get_schema_with_attributes(UUID);

-- Atomic schema definition function (depends on enqueue_schema_defined_event)
DROP FUNCTION IF EXISTS define_schema_with_attributes(VARCHAR, JSONB, VARCHAR);

-- Event outbox function
DROP FUNCTION IF EXISTS enqueue_schema_defined_event(UUID, VARCHAR, INTEGER, VARCHAR);

-- ============================================================================
-- 2. Drop triggers on entity_schemas
-- ============================================================================
DROP TRIGGER IF EXISTS update_entity_schemas_modtime ON entity_schemas;

-- ============================================================================
-- 3. Drop tables (child first due to FK constraints)
-- ============================================================================
DROP TABLE IF EXISTS entity_schema_attributes CASCADE;
DROP TABLE IF EXISTS entity_schemas CASCADE;
DROP TABLE IF EXISTS outbox_events CASCADE;

-- ============================================================================
-- 4. Drop ENUM type
-- ============================================================================
DROP TYPE IF EXISTS entity_management_attribute_type;

-- ============================================================================
-- 5. Drop helper function (only if no other triggers reference it)
-- ============================================================================
-- NOTE: update_modified_column() is shared across many migrations.
-- Only drop it if no other tables still use it.
-- DO NOT DROP: DROP FUNCTION IF EXISTS update_modified_column();
-- It is kept for backward compatibility with other migrations.

COMMIT;
