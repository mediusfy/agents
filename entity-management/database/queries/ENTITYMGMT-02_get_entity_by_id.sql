-- Query: ENTITYMGMT-02_get_entity_by_id.sql
-- Story: ENTITYMGMT-02 — User creates an entity with idempotency support (7-day TTL)
-- Bounded Context: Entity Management
--
-- Retrieves a complete entity by its ID, excluding soft-deleted entities
-- by default. Pass $2 = TRUE to include soft-deleted entities.
--
-- Used by the application layer for read/update/delete operations.
--
-- Usage:
--   SELECT * FROM get_entity_by_id('e1000001-0000-4000-8000-000000000001');
--   SELECT * FROM get_entity_by_id('e1000001-0000-4000-8000-000000000001', TRUE);
-- ============================================================================

-- :name get-entity-by-id
-- :command :query
-- :result :one
SELECT * FROM get_entity_by_id(
    p_entity_id       := $1::UUID,
    p_include_deleted := $2::BOOLEAN
);
