

-- ============================================================================
-- RESOURCE-01: WebSocket Schema — ROLLBACK
-- ============================================================================

BEGIN;

DROP TABLE IF EXISTS ws_event_buffer CASCADE;
DROP TABLE IF EXISTS ws_sessions CASCADE;

DROP TYPE IF EXISTS ws_session_state;

COMMIT;
