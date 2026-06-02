

-- ============================================================================
-- RESOURCE-01: Regional Data Plane Schema — ROLLBACK
-- ============================================================================

BEGIN;

DROP TABLE IF EXISTS deployments CASCADE;
DROP TABLE IF EXISTS board_states CASCADE;
DROP TABLE IF EXISTS audit_chain_links CASCADE;
DROP TABLE IF EXISTS audit_wal CASCADE;
DROP TABLE IF EXISTS resource_events CASCADE;
DROP TABLE IF EXISTS resources CASCADE;

DROP TYPE IF EXISTS deploy_status;
DROP TYPE IF EXISTS event_type;

DROP FUNCTION IF EXISTS create_audit_wal_partition();
DROP FUNCTION IF EXISTS verify_audit_chain(UUID);

COMMIT;
