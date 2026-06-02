-- Migration: 011_clusterconnect_02_connection_status
-- Story: CLUSTERCONNECT-02 — View connected clusters with connection status indicators
-- Description: Adds connection status tracking to cluster_connections, a cluster_connection_status enum,
--              and a cluster_health_checks table for historical health data.
--              Enables the unified cluster list with reachability indicators.

-- =============================================================================
-- UP
-- =============================================================================

-- 1. Create the connection status enum
DO $$ BEGIN
    CREATE TYPE cluster_connection_status AS ENUM (
        'CONNECTED',
        'DEGRADED',
        'DISCONNECTED',
        'UNREACHABLE',
        'PENDING',
        'UNKNOWN'
    );
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- 2. Ensure the updated_at trigger function exists (idempotent)
CREATE OR REPLACE FUNCTION update_modified_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

-- 3. Create the cluster_connections table
CREATE TABLE IF NOT EXISTS cluster_connections (
    -- Primary key
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Core identity
    name                VARCHAR(255) NOT NULL,
    slug                VARCHAR(128) NOT NULL,
    description         TEXT,

    -- Connection details
    api_endpoint        VARCHAR(1024) NOT NULL,
    dashboard_url       VARCHAR(1024),
    region              VARCHAR(128),
    provider            VARCHAR(64),   -- e.g. 'gcp', 'aws', 'azure', 'on-prem'
    version             VARCHAR(64),   -- cluster platform version

    -- Authentication (encrypted via application layer)
    auth_type           VARCHAR(64) NOT NULL DEFAULT 'api_key',
    auth_config_enc     BYTEA,

    -- Connection status (CLUSTERCONNECT-02)
    connection_status   cluster_connection_status NOT NULL DEFAULT 'PENDING',
    status_message      TEXT,
    last_ping_at        TIMESTAMPTZ,
    last_status_change  TIMESTAMPTZ,
    consecutive_failures INTEGER NOT NULL DEFAULT 0,

    -- Labels/tags for filtering and organization
    labels              JSONB NOT NULL DEFAULT '{}',

    -- Soft delete / lifecycle
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    deactivated_at      TIMESTAMPTZ,

    -- Timestamps
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 4. Create the cluster_health_checks table (partitioned)
CREATE TABLE IF NOT EXISTS cluster_health_checks (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- FK to cluster
    cluster_id          UUID NOT NULL REFERENCES cluster_connections(id) ON DELETE CASCADE,

    -- Check result
    status              cluster_connection_status NOT NULL,
    response_time_ms    INTEGER,
    http_status_code    SMALLINT,
    error_message       TEXT,
    check_source        VARCHAR(128) DEFAULT 'scheduler',

    -- Metadata
    metadata            JSONB NOT NULL DEFAULT '{}',

    -- Timestamps
    checked_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
)
PARTITION BY RANGE (checked_at);

-- 5. Create initial monthly partitions
CREATE TABLE IF NOT EXISTS cluster_health_checks_2026_06
    PARTITION OF cluster_health_checks
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');

CREATE TABLE IF NOT EXISTS cluster_health_checks_2026_07
    PARTITION OF cluster_health_checks
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');

-- 6. Triggers for auto-updating timestamps
CREATE TRIGGER update_cluster_connections_modtime
    BEFORE UPDATE ON cluster_connections
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

CREATE TRIGGER update_cluster_health_checks_modtime
    BEFORE UPDATE ON cluster_health_checks
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

-- 7. Indexes for cluster_connections
CREATE UNIQUE INDEX IF NOT EXISTS idx_cluster_connections_slug ON cluster_connections(slug);
CREATE INDEX IF NOT EXISTS idx_cluster_connections_status ON cluster_connections(connection_status);
CREATE INDEX IF NOT EXISTS idx_cluster_connections_is_active ON cluster_connections(is_active);
CREATE INDEX IF NOT EXISTS idx_cluster_connections_region ON cluster_connections(region);
CREATE INDEX IF NOT EXISTS idx_cluster_connections_provider ON cluster_connections(provider);
CREATE INDEX IF NOT EXISTS idx_cluster_connections_labels ON cluster_connections USING GIN (labels);
CREATE INDEX IF NOT EXISTS idx_cluster_connections_last_ping ON cluster_connections(last_ping_at DESC);
CREATE INDEX IF NOT EXISTS idx_cluster_connections_consecutive_failures
    ON cluster_connections(consecutive_failures)
    WHERE consecutive_failures > 0;
CREATE INDEX IF NOT EXISTS idx_cluster_connections_status_change
    ON cluster_connections(last_status_change DESC);

-- 8. Indexes for cluster_health_checks
CREATE INDEX IF NOT EXISTS idx_health_checks_cluster_id ON cluster_health_checks(cluster_id);
CREATE INDEX IF NOT EXISTS idx_health_checks_cluster_status
    ON cluster_health_checks(cluster_id, status, checked_at DESC);
CREATE INDEX IF NOT EXISTS idx_health_checks_checked_at
    ON cluster_health_checks(checked_at DESC);
CREATE INDEX IF NOT EXISTS idx_health_checks_status
    ON cluster_health_checks(status);

-- 9. Create a view for the unified cluster list with latest health indicator
CREATE OR REPLACE VIEW v_cluster_list_with_health AS
SELECT
    cc.id,
    cc.name,
    cc.slug,
    cc.description,
    cc.api_endpoint,
    cc.dashboard_url,
    cc.region,
    cc.provider,
    cc.version,
    cc.connection_status,
    cc.status_message,
    cc.last_ping_at,
    cc.last_status_change,
    cc.consecutive_failures,
    cc.labels,
    cc.is_active,
    cc.created_at,
    cc.updated_at,
    -- Latest health check metrics
    hc.response_time_ms AS last_response_time_ms,
    hc.http_status_code AS last_http_status,
    hc.error_message AS last_error_message,
    hc.checked_at AS last_health_check_at,
    -- Status indicator for UI
    CASE cc.connection_status
        WHEN 'CONNECTED' THEN 'healthy'
        WHEN 'DEGRADED' THEN 'degraded'
        WHEN 'DISCONNECTED' THEN 'warning'
        WHEN 'UNREACHABLE' THEN 'critical'
        WHEN 'PENDING' THEN 'pending'
        ELSE 'unknown'
    END AS status_indicator
FROM cluster_connections cc
LEFT JOIN LATERAL (
    SELECT response_time_ms, http_status_code, error_message, checked_at
    FROM cluster_health_checks
    WHERE cluster_id = cc.id
    ORDER BY checked_at DESC
    LIMIT 1
) hc ON TRUE
WHERE cc.is_active = TRUE;

-- =============================================================================
-- DOWN
-- =============================================================================

-- DROP VIEW IF EXISTS v_cluster_list_with_health;
-- DROP INDEX IF EXISTS idx_cluster_connections_slug;
-- DROP INDEX IF EXISTS idx_cluster_connections_status;
-- DROP INDEX IF EXISTS idx_cluster_connections_is_active;
-- DROP INDEX IF EXISTS idx_cluster_connections_region;
-- DROP INDEX IF EXISTS idx_cluster_connections_provider;
-- DROP INDEX IF EXISTS idx_cluster_connections_labels;
-- DROP INDEX IF EXISTS idx_cluster_connections_last_ping;
-- DROP INDEX IF EXISTS idx_cluster_connections_consecutive_failures;
-- DROP INDEX IF EXISTS idx_cluster_connections_status_change;
-- DROP INDEX IF EXISTS idx_health_checks_cluster_id;
-- DROP INDEX IF EXISTS idx_health_checks_cluster_status;
-- DROP INDEX IF EXISTS idx_health_checks_checked_at;
-- DROP INDEX IF EXISTS idx_health_checks_status;
-- DROP TABLE IF EXISTS cluster_health_checks_2026_07;
-- DROP TABLE IF EXISTS cluster_health_checks_2026_06;
-- DROP TABLE IF EXISTS cluster_health_checks;
-- DROP TRIGGER IF EXISTS update_cluster_connections_modtime ON cluster_connections;
-- DROP TRIGGER IF EXISTS update_cluster_health_checks_modtime ON cluster_health_checks;
-- DROP TABLE IF EXISTS cluster_connections;
-- DROP TYPE IF EXISTS cluster_connection_status;
