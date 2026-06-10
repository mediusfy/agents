-- Query: ENTITYMGMT-02_check_entity_exists.sql
-- Story: ENTITYMGMT-02 — User creates an entity with idempotency support (7-day TTL)
-- Bounded Context: Entity Management
--
-- Checks if an entity with the given (schema_id, name) already exists.
-- Used for conflict detection before entity creation.
--
-- The schema-level unique constraint (uq_entities_schema_name) prevents
-- duplicate names per schema type. This query proactively checks before
-- the INSERT to provide a better error message.
--
-- Usage:
--   SELECT * FROM check_entity_exists(
--     'c0000001-0000-4000-8000-000000000001',  -- schema_id (Customer)
--     'Alice'                                     -- entity name
--   );
-- ============================================================================

-- :name check-entity-exists
-- :command :query
-- :result :one
SELECT
    e.id,
    e.name,
    e.type,
    e.region,
    e.data_residency_zone,
    e.status,
    e.version,
    e.created_at
FROM entities e
WHERE e.schema_id = $1::UUID
  AND e.name = $2::VARCHAR(512)
  AND e.status != 'deleted';
