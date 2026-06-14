-- Query: ENTITYMGMT-02_prune_expired_idempotency.sql
-- Story: ENTITYMGMT-02 — User creates an entity with idempotency support (7-day TTL)
-- Bounded Context: Entity Management
--
-- Cleans up idempotency tracking records older than their TTL.
-- Returns the number of deleted rows.
-- Call this periodically via pg_cron or application scheduler (e.g., daily).
--
-- Gherkin SCENARIO 3: Expired keys are treated as non-existent, allowing
-- new entity creation with the same key after the TTL window.
-- This function ensures expired rows are physically removed from the table.
--
-- Usage:
--   SELECT prune_expired_idempotency();
-- ============================================================================

-- :name prune-expired-idempotency
-- :command :query
-- :result :one
SELECT prune_expired_idempotency() AS deleted_count;
