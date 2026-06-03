-- Query: ENTITYMGMT-03_get_entity_by_id.sql
-- Story: ENTITYMGMT-03 — User retrieves an entity by ID with observability event
-- Bounded Context: Entity Management
--
-- Gherkin SCENARIO 1 (retrieved):
--   Returns found=TRUE, is_deleted=FALSE, full entity JSON payload,
--   audit_id for observability tracking, and event_id for the enqueued
--   entitymanagement.entity.read domain event.
--
-- Gherkin SCENARIO 2 (not found):
--   Returns found=FALSE, entity_json=NULL, event_id=NULL.
--   No entity.read event is published.
--
-- Usage:
--   SELECT * FROM get_entity_by_id_with_audit(
--     p_entity_id      := 'e1000001-0000-4000-8000-000000000001',
--     p_request_id     := 'req-abc-123',
--     p_read_by        := 'user-abc-123',
--     p_request_origin := 'api-gateway'
--   );
--
-- Returns columns:
--   found         BOOLEAN    — Whether the entity exists
--   is_deleted    BOOLEAN    — Whether the entity is soft-deleted
--   entity_json   JSONB      — Full entity payload (NULL if not found)
--                              Including: id, schema_id, schema_version, name, type,
--                              region, data_residency_zone, status, version,
--                              attributes, metadata, created_at, updated_at, deleted_at
--   audit_id      UUID       — ID of the audit log entry
--   event_id      UUID       — ID of the enqueued entity.read event (NULL if not found)
-- ============================================================================

-- :name get-entity-by-id-with-audit
-- :command :query
-- :result :one
SELECT * FROM get_entity_by_id_with_audit(
    p_entity_id      := $1::VARCHAR(64),
    p_request_id     := $2::VARCHAR(255),
    p_read_by        := $3::VARCHAR(255),
    p_request_origin := $4::VARCHAR(128)
);
