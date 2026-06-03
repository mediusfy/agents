-- Query: ENTITYMGMT-02_create_entity.sql
-- Story: ENTITYMGMT-02 — User creates an entity with idempotency support (7-day TTL)
-- Bounded Context: Entity Management
--
-- Gherkin SCENARIO 1: Creates a new entity conforming to a schema, with
-- request-level idempotency and transactional outbox event emission.
--
-- This query is the atomic unit of work for the CreateEntity use case.
-- It is executed within a single database transaction:
--   1. Checks idempotency key (if provided)
--      - Found and non-expired → returns existing entity (HTTP 200, SCENARIO 2)
--      - Not found or expired → proceeds to create new entity (SCENARIO 1/3)
--   2. Inserts entity row with status='active' and version=1
--   3. Computes data_residency_zone from region (generated column)
--   4. Enqueues entitymanagement.entity.created event into outbox_events
--   5. Records idempotency key mapping with 7-day TTL
--
-- Returns:
--   out_entity_id   UUID     — The entity ID (new or existing)
--   out_version     INTEGER  — Entity version (1 for new, existing for replay)
--   out_status      TEXT     — 'active' for new, existing for replay
--   out_event_id    UUID     — Event ID (NULL on idempotent replay)
--   out_is_new      BOOLEAN  — TRUE if a new entity was created
--   out_created_at  TIMESTAMPTZ — Created timestamp
--
-- SCENARIO 2 (idempotent replay): Returns existing entity with out_is_new=FALSE
--   and out_event_id=NULL (no duplicate event emitted).
--
-- SCENARIO 3 (expired key): Treated as new request (out_is_new=TRUE) because
--   the expired row is effectively ignored.
--
-- Usage:
--   SELECT * FROM create_entity_with_idempotency(
--     p_schema_id       := 'c0000001-0000-4000-8000-000000000001',
--     p_schema_version  := 1,
--     p_name            := 'Alice',
--     p_type            := 'customer',
--     p_region          := 'eu-west-1',
--     p_attributes      := '{"email": "alice@example.com", "name": "Alice"}'::jsonb,
--     p_metadata        := '{}'::jsonb,
--     p_idempotency_key := 'create-customer-001',
--     p_ttl_days        := 7
--   );
-- ============================================================================

-- :name create-entity-with-idempotency
-- :command :query
-- :result :one
SELECT * FROM create_entity_with_idempotency(
    p_schema_id       := $1::UUID,
    p_schema_version  := $2::INTEGER,
    p_name            := $3::VARCHAR(512),
    p_type            := $4::VARCHAR(255),
    p_region          := $5::VARCHAR(64),
    p_attributes      := $6::JSONB,
    p_metadata        := $7::JSONB,
    p_idempotency_key := $8::TEXT,
    p_ttl_days        := $9::INTEGER
);
