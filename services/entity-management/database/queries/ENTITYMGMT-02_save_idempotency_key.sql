-- Query: ENTITYMGMT-02_save_idempotency_key.sql
-- Story: ENTITYMGMT-02 — User creates an entity with idempotency support (7-day TTL)
-- Bounded Context: Entity Management
--
-- Records a client-supplied idempotency key → entity ID mapping with 7-day TTL.
-- Uses UPSERT semantics so that re-recording the same key is idempotent.
--
-- Gherkin SCENARIO 1: Called after successful entity creation.
--   "the idempotency key is stored with a 7-day TTL"
--
-- Gherkin SCENARIO 2: If the key already exists, this is a no-op (ON CONFLICT).
--   "no duplicate entity is created"
--
-- Usage:
--   PERFORM save_idempotency_key(
--     p_request_key := 'create-customer-001',
--     p_entity_id   := 'e1000001-0000-4000-8000-000000000001',
--     p_ttl_days    := 7
--   );
-- ============================================================================

-- :name save-idempotency-key
-- :command :execute
-- :result :raw
SELECT save_idempotency_key(
    p_request_key := $1::TEXT,
    p_entity_id   := $2::UUID,
    p_ttl_days    := $3::INTEGER
);
