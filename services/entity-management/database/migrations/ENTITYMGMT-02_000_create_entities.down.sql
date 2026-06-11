-- Migration: ENTITYMGMT-02_000_create_entities.down.sql
-- Story: ENTITYMGMT-02 — Rollback entity creation and idempotency support
-- Bounded Context: Entity Management
--
-- Reverses ENTITYMGMT-02_000_create_entities.up.sql
--
-- Ordered rollback:
--   1. Drop functions (depend on tables but no inter-function dependencies)
--   2. Drop triggers on entities
--   3. Drop tables (request_idempotency first due to FK to entities)
--   4. Drop ENUM type
--   5. Drop helper function (compute_data_residency_zone)
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. Drop functions (in reverse dependency order)
-- ============================================================================

-- Entity query/validation functions
DROP FUNCTION IF EXISTS count_entities_by_schema(UUID, entity_status, BOOLEAN);
DROP FUNCTION IF EXISTS list_entities_by_schema(UUID, entity_status, INTEGER, INTEGER, BOOLEAN);
DROP FUNCTION IF EXISTS get_entity_by_id(UUID, BOOLEAN);

-- Idempotency management
DROP FUNCTION IF EXISTS prune_expired_idempotency();
DROP FUNCTION IF EXISTS get_entity_by_idempotency_key(TEXT);

-- Core atomic helper (depends on enqueue_entity_created_event and save_idempotency_key)
DROP FUNCTION IF EXISTS create_entity_with_idempotency(UUID, INTEGER, VARCHAR, VARCHAR, VARCHAR, JSONB, JSONB, TEXT, INTEGER);

-- Idempotency key storage
DROP FUNCTION IF EXISTS save_idempotency_key(TEXT, UUID, INTEGER);

-- Event outbox function
DROP FUNCTION IF EXISTS enqueue_entity_created_event(UUID, UUID, VARCHAR, VARCHAR, VARCHAR, TEXT, INTEGER, TEXT, JSONB, JSONB);

-- Data residency zone mapper
DROP FUNCTION IF EXISTS compute_data_residency_zone(TEXT);

-- ============================================================================
-- 2. Drop triggers on entities
-- ============================================================================
DROP TRIGGER IF EXISTS update_entities_modtime ON entities;

-- ============================================================================
-- 3. Drop indexes explicitly (for idempotent down migration)
-- ============================================================================
DROP INDEX IF EXISTS idx_entities_schema_id;
DROP INDEX IF EXISTS idx_entities_schema_status;
DROP INDEX IF EXISTS idx_entities_schema_status_created;
DROP INDEX IF EXISTS idx_entities_region_status;
DROP INDEX IF EXISTS idx_entities_data_residency_zone;
DROP INDEX IF EXISTS idx_entities_type;
DROP INDEX IF EXISTS idx_entities_status;
DROP INDEX IF EXISTS idx_entities_created_at;
DROP INDEX IF EXISTS idx_entities_updated_at;
DROP INDEX IF EXISTS idx_entities_attributes;
DROP INDEX IF EXISTS idx_entities_metadata;
DROP INDEX IF EXISTS idx_entities_active;
DROP INDEX IF EXISTS idx_entities_version;
DROP INDEX IF EXISTS idx_request_idempotency_expires_at;
DROP INDEX IF EXISTS idx_request_idempotency_entity_id;
DROP INDEX IF EXISTS idx_request_idempotency_active;

-- ============================================================================
-- 4. Drop tables (child first due to FK constraints)
-- ============================================================================
DROP TABLE IF EXISTS request_idempotency CASCADE;
DROP TABLE IF EXISTS entities CASCADE;

-- ============================================================================
-- 5. Drop ENUM type (only if no other tables depend on it)
-- ============================================================================
DROP TYPE IF EXISTS entity_status;

COMMIT;
