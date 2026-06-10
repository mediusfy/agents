-- Query: ENTITYMGMT-02_list_entities_by_schema.sql
-- Story: ENTITYMGMT-02 — User creates an entity with idempotency support (7-day TTL)
-- Bounded Context: Entity Management
--
-- Lists all entities for a given schema, with optional status filter
-- and offset-based pagination. Excludes soft-deleted entities by default.
--
-- The data_residency_zone column is a stored generated column computed
-- automatically from the region field via compute_data_residency_zone().
--
-- Usage:
--   SELECT * FROM list_entities_by_schema(
--     'c0000001-0000-4000-8000-000000000001',  -- schema_id
--     'active',                                   -- status filter (NULL = all)
--     50,                                         -- limit
--     0,                                          -- offset
--     FALSE                                       -- include_deleted
--   );
-- ============================================================================

-- :name list-entities-by-schema
-- :command :query
-- :result :many
SELECT * FROM list_entities_by_schema(
    p_schema_id       := $1::UUID,
    p_status          := $2::entity_status,
    p_limit           := $3::INTEGER,
    p_offset          := $4::INTEGER,
    p_include_deleted := $5::BOOLEAN
);
