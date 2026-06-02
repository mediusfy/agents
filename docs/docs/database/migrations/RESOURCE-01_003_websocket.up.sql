

-- ============================================================================
-- RESOURCE-01: WebSocket Session & Event Buffer Tracking
-- Description: WebSocket session state tracking for real-time K8s resource
--              streaming. Primary buffer is Redis; this table provides durable
--              session metadata and fallback tracking.
-- ============================================================================

BEGIN;

-- --------------------------------------------------------------------------
-- 1. Helper: updated_at trigger (idempotent)
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_modified_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- --------------------------------------------------------------------------
-- 2. enum types
-- --------------------------------------------------------------------------
DO $$ BEGIN
    CREATE TYPE ws_session_state AS ENUM (
        'connecting', 'connected', 'reconnecting', 'disconnected', 'expired'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- --------------------------------------------------------------------------
-- 3. ws_sessions — WebSocket session metadata
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ws_sessions (
    id              UUID             PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID             NOT NULL,
    cluster_id      UUID,                        -- NULL = global stream (all clusters)
    client_id       VARCHAR(255)     NOT NULL,    -- Client-generated ID for reconnection
    state           ws_session_state NOT NULL DEFAULT 'connected',
    last_heartbeat  TIMESTAMPTZ,
    created_at      TIMESTAMPTZ      NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ      NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_ws_client UNIQUE (client_id)
);

-- Find all sessions for a user across clusters
CREATE INDEX IF NOT EXISTS idx_ws_sessions_user
    ON ws_sessions(user_id, state);
-- Find stale sessions for cleanup
CREATE INDEX IF NOT EXISTS idx_ws_sessions_stale
    ON ws_sessions(last_heartbeat)
    WHERE state IN ('connected', 'reconnecting');
-- Find sessions per cluster for resource-scoped broadcasts
CREATE INDEX IF NOT EXISTS idx_ws_sessions_cluster
    ON ws_sessions(cluster_id, state)
    WHERE cluster_id IS NOT NULL;

CREATE TRIGGER trg_ws_sessions_updated_at
    BEFORE UPDATE ON ws_sessions
    FOR EACH ROW EXECUTE FUNCTION update_modified_column();

COMMENT ON TABLE  ws_sessions IS 'WebSocket session metadata — primary event buffer is Redis-backed';
COMMENT ON COLUMN ws_sessions.client_id IS 'Client-generated opaque ID for reconnection correlation';
COMMENT ON COLUMN ws_sessions.last_heartbeat IS 'Last ping received from client; NULL if never received';

-- --------------------------------------------------------------------------
-- 4. ws_event_buffer — Durable tracking table for Redis-backed event buffer
--    This is NOT the primary buffer (Redis is); it records buffer metadata
--    for replay/recovery purposes.
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ws_event_buffer (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id      UUID        NOT NULL REFERENCES ws_sessions(id) ON DELETE CASCADE,
    resource_id     UUID        REFERENCES resources(id) ON DELETE SET NULL,
    event_type      VARCHAR(10) NOT NULL,     -- ADDED, MODIFIED, DELETED
    buffer_key      VARCHAR(255) NOT NULL,    -- Redis key where event was buffered
    buffered_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    delivered_at    TIMESTAMPTZ,              -- NULL = not yet delivered
    expiry_at       TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '1 hour')
);

-- Find undelivered events for a session
CREATE INDEX IF NOT EXISTS idx_ws_buffer_undelivered
    ON ws_event_buffer(session_id, buffered_at)
    WHERE delivered_at IS NULL;
-- Cleanup expired events
CREATE INDEX IF NOT EXISTS idx_ws_buffer_expiry
    ON ws_event_buffer(expiry_at)
    WHERE delivered_at IS NULL;
-- Find events for a resource across sessions (for targeted invalidation)
CREATE INDEX IF NOT EXISTS idx_ws_buffer_resource
    ON ws_event_buffer(resource_id, event_type)
    WHERE resource_id IS NOT NULL;

COMMENT ON TABLE  ws_event_buffer IS 'Metadata table for Redis-backed WebSocket event buffer — supports replay/recovery';
COMMENT ON COLUMN ws_event_buffer.buffer_key IS 'Redis key (e.g., ws:buffer:{session_id}:{event_id})';
COMMENT ON COLUMN ws_event_buffer.delivered_at IS 'Set when event is acknowledged as delivered; NULL = pending';
COMMENT ON COLUMN ws_event_buffer.expiry_at IS 'Auto-expiry for event buffer entries (default 1 hour)';

-- --------------------------------------------------------------------------
-- 5. Row-Level Security
-- --------------------------------------------------------------------------
ALTER TABLE ws_sessions      ENABLE ROW LEVEL SECURITY;
ALTER TABLE ws_event_buffer  ENABLE ROW LEVEL SECURITY;

-- Users see only their own sessions
CREATE POLICY p_ws_sessions_self ON ws_sessions
    USING (user_id = current_setting('app.current_user_id')::UUID);

-- Event buffer visibility through session ownership
CREATE POLICY p_ws_event_buffer_self ON ws_event_buffer
    USING (
        EXISTS (
            SELECT 1 FROM ws_sessions
            WHERE ws_sessions.id = ws_event_buffer.session_id
              AND ws_sessions.user_id = current_setting('app.current_user_id')::UUID
        )
    );

-- Admin overrides
CREATE POLICY p_ws_sessions_admin ON ws_sessions
    FOR ALL
    USING (current_setting('app.current_role') = 'cluster-admin');

CREATE POLICY p_ws_event_buffer_admin ON ws_event_buffer
    FOR ALL
    USING (current_setting('app.current_role') = 'cluster-admin');

COMMIT;
