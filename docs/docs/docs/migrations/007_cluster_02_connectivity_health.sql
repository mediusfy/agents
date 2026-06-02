-- ============================================================================
-- Migration 007: CLUSTER-02 - Continuous Cluster Connectivity & Health Monitoring
-- ============================================================================
-- Description: Adds real-time connectivity verification, heartbeat monitoring,
--   certificate expiry tracking, configurable health checks, and live status
--   aggregation for the ClusterConnect bounded context.
--
-- Depends on: 006_cluster_01_cluster_connections.sql (CLUSTER-01)
-- Requires: pg_partman extension for monthly partition management
--
-- Tables added:
--   connectivity_check_config
--   connectivity_check_results (partitioned by month)
--   cluster_heartbeats (partitioned by month)
--   cluster_certificate_expiry
--   cluster_health_scores (partitioned by month)
--   cluster_connectivity_status
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. ENUM Types
-- ============================================================================
CREATE TYPE connectivity_protocol AS ENUM (
    'grpc',
    'https',
    'tcp',
    'icmp',
    'custom'
);

CREATE TYPE check_result_type AS ENUM (
    'success',
    'failure',
    'timeout',
    'error'
);

CREATE TYPE cluster_health_status AS ENUM (
    'healthy',
    'degraded',
    'unhealthy',
    'unknown'
);

CREATE TYPE certificate_severity AS ENUM (
    'critical',
    'warning',
    'info'
);

-- ============================================================================
-- 2. Connectivity Check Configuration
-- ============================================================================
-- Defines how the system verifies connectivity to each cluster.
-- Supports multiple protocols and configurable intervals per cluster.
CREATE TABLE IF NOT EXISTS connectivity_check_config (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster_id          UUID NOT NULL REFERENCES cluster_connections(id) ON DELETE CASCADE,
    protocol            connectivity_protocol NOT NULL DEFAULT 'https',
    endpoint            TEXT NOT NULL,
    port                INTEGER NOT NULL DEFAULT 443,
    check_interval_secs INTEGER NOT NULL DEFAULT 30,
    timeout_ms          INTEGER NOT NULL DEFAULT 5000,
    retry_count         INTEGER NOT NULL DEFAULT 3,
    health_threshold    INTEGER NOT NULL DEFAULT 3,
        -- Number of consecutive failures before marking unhealthy
    config_metadata     JSONB DEFAULT '{}'::jsonb,
        -- Protocol-specific configuration (e.g., CA cert path, headers)
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at          TIMESTAMPTZ DEFAULT NULL,

    CONSTRAINT unique_active_check_per_cluster
        UNIQUE (cluster_id, protocol, endpoint)
        WHERE deleted_at IS NULL,
    CONSTRAINT valid_check_interval
        CHECK (check_interval_secs BETWEEN 5 AND 3600),
    CONSTRAINT valid_timeout
        CHECK (timeout_ms BETWEEN 100 AND 60000),
    CONSTRAINT valid_port
        CHECK (port BETWEEN 1 AND 65535),
    CONSTRAINT valid_health_threshold
        CHECK (health_threshold BETWEEN 1 AND 20)
);

-- Indexes for check config
CREATE INDEX idx_connectivity_check_config_cluster
    ON connectivity_check_config(cluster_id)
    WHERE deleted_at IS NULL;
CREATE INDEX idx_connectivity_check_config_active
    ON connectivity_check_config(is_active)
    WHERE is_active = TRUE AND deleted_at IS NULL;
CREATE INDEX idx_connectivity_check_config_metadata
    ON connectivity_check_config USING GIN (config_metadata jsonb_path_ops);

-- Trigger for auto-updating updated_at
CREATE TRIGGER update_connectivity_check_config_modtime
    BEFORE UPDATE ON connectivity_check_config
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

-- ============================================================================
-- 3. Connectivity Check Results (Partitioned by Month)
-- ============================================================================
-- Stores every individual connectivity check result.
-- Partitioned by month using pg_partman for efficient time-range queries.
CREATE TABLE IF NOT EXISTS connectivity_check_results (
    id                  UUID NOT NULL DEFAULT gen_random_uuid(),
    check_config_id     UUID NOT NULL REFERENCES connectivity_check_config(id) ON DELETE CASCADE,
    cluster_id          UUID NOT NULL REFERENCES cluster_connections(id) ON DELETE CASCADE,
    result              check_result_type NOT NULL,
    latency_ms          DOUBLE PRECISION DEFAULT NULL,
    status_code         INTEGER DEFAULT NULL,
    error_message       TEXT DEFAULT NULL,
    checked_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (id, checked_at)
) PARTITION BY RANGE (checked_at);

-- Create initial partition via pg_partman
-- Production would use: SELECT partman.create_parent('public.connectivity_check_results', 'checked_at', 'native', 'monthly');
-- For bootstrap, create the first 3 months manually:
CREATE TABLE IF NOT EXISTS connectivity_check_results_2026_06
    PARTITION OF connectivity_check_results
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE IF NOT EXISTS connectivity_check_results_2026_07
    PARTITION OF connectivity_check_results
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE IF NOT EXISTS connectivity_check_results_2026_08
    PARTITION OF connectivity_check_results
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');

-- Critical indexes for check results
CREATE INDEX idx_check_results_cluster_checked
    ON connectivity_check_results(cluster_id, checked_at DESC);
CREATE INDEX idx_check_results_config_checked
    ON connectivity_check_results(check_config_id, checked_at DESC);
CREATE INDEX idx_check_results_failures
    ON connectivity_check_results(cluster_id, checked_at DESC)
    WHERE result IN ('failure', 'timeout', 'error');
CREATE INDEX idx_check_results_result_type
    ON connectivity_check_results(result, checked_at DESC);
-- BRIN index for time-series partition pruning
CREATE INDEX idx_check_results_checked_brin
    ON connectivity_check_results USING BRIN (checked_at)
    WITH (pages_per_range = 32);

-- ============================================================================
-- 4. Cluster Heartbeats (Partitioned by Month)
-- ============================================================================
-- Fine-grained heartbeat pings from each cluster agent.
-- Used to calculate "last seen" time and detect connectivity issues.
CREATE TABLE IF NOT EXISTS cluster_heartbeats (
    id                  UUID NOT NULL DEFAULT gen_random_uuid(),
    cluster_id          UUID NOT NULL REFERENCES cluster_connections(id) ON DELETE CASCADE,
    agent_version       TEXT NOT NULL,
    node_count          INTEGER DEFAULT NULL,
    pod_count           INTEGER DEFAULT NULL,
    cpu_usage_pct       DOUBLE PRECISION DEFAULT NULL,
    memory_usage_pct    DOUBLE PRECISION DEFAULT NULL,
    heartbeat_metadata  JSONB DEFAULT '{}'::jsonb,
        -- Additional telemetry from the cluster agent
    received_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (id, received_at)
) PARTITION BY RANGE (received_at);

-- Bootstrap partitions
CREATE TABLE IF NOT EXISTS cluster_heartbeats_2026_06
    PARTITION OF cluster_heartbeats
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE IF NOT EXISTS cluster_heartbeats_2026_07
    PARTITION OF cluster_heartbeats
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE IF NOT EXISTS cluster_heartbeats_2026_08
    PARTITION OF cluster_heartbeats
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');

-- Indexes for heartbeats
CREATE INDEX idx_heartbeats_cluster_received
    ON cluster_heartbeats(cluster_id, received_at DESC);
CREATE INDEX idx_heartbeats_received_brin
    ON cluster_heartbeats USING BRIN (received_at)
    WITH (pages_per_range = 32);
CREATE INDEX idx_heartbeats_metadata
    ON cluster_heartbeats USING GIN (heartbeat_metadata jsonb_path_ops);

-- ============================================================================
-- 5. Certificate Expiry Tracking
-- ============================================================================
-- Tracks TLS certificate expiration for clusters, enabling proactive alerts.
CREATE TABLE IF NOT EXISTS cluster_certificate_expiry (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster_id          UUID NOT NULL REFERENCES cluster_connections(id) ON DELETE CASCADE,
    common_name         TEXT NOT NULL,
    issuer              TEXT DEFAULT NULL,
    serial_number       TEXT DEFAULT NULL,
    fingerprint_sha256  TEXT DEFAULT NULL,
    not_before          TIMESTAMPTZ NOT NULL,
    not_after           TIMESTAMPTZ NOT NULL,
    days_until_expiry   INTEGER GENERATED ALWAYS AS
        (EXTRACT(DAY FROM (not_after - NOW()))) STORED,
    severity            certificate_severity NOT NULL DEFAULT 'info',
    is_renewed          BOOLEAN NOT NULL DEFAULT FALSE,
    renewed_by_cert_id  UUID DEFAULT NULL,
    cert_metadata       JSONB DEFAULT '{}'::jsonb,
    discovered_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_checked_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at          TIMESTAMPTZ DEFAULT NULL,

    CONSTRAINT fk_renewed_by
        FOREIGN KEY (renewed_by_cert_id) REFERENCES cluster_certificate_expiry(id)
        ON DELETE SET NULL,
    CONSTRAINT valid_expiry_window
        CHECK (not_after > not_before)
);

-- Indexes for certificate expiry
CREATE INDEX idx_cert_expiry_cluster
    ON cluster_certificate_expiry(cluster_id)
    WHERE deleted_at IS NULL;
CREATE INDEX idx_cert_expiry_not_after
    ON cluster_certificate_expiry(not_after)
    WHERE deleted_at IS NULL AND is_renewed = FALSE;
CREATE INDEX idx_cert_expiry_severity
    ON cluster_certificate_expiry(severity)
    WHERE deleted_at IS NULL AND is_renewed = FALSE;
CREATE INDEX idx_cert_expiry_days_remaining
    ON cluster_certificate_expiry(days_until_expiry)
    WHERE deleted_at IS NULL AND is_renewed = FALSE;
CREATE INDEX idx_cert_expiry_fingerprint
    ON cluster_certificate_expiry(fingerprint_sha256)
    WHERE deleted_at IS NULL;
CREATE INDEX idx_cert_expiry_metadata
    ON cluster_certificate_expiry USING GIN (cert_metadata jsonb_path_ops);

-- Trigger for auto-updating updated_at
CREATE TRIGGER update_cluster_certificate_expiry_modtime
    BEFORE UPDATE ON cluster_certificate_expiry
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

-- ============================================================================
-- 6. Cluster Health Scores (Partitioned by Month)
-- ============================================================================
-- Pre-aggregated health scores per cluster per time window.
-- Powers the dashboard's live health indicators without expensive queries.
CREATE TABLE IF NOT EXISTS cluster_health_scores (
    id                  UUID NOT NULL DEFAULT gen_random_uuid(),
    cluster_id          UUID NOT NULL REFERENCES cluster_connections(id) ON DELETE CASCADE,
    window_start        TIMESTAMPTZ NOT NULL,
    window_end          TIMESTAMPTZ NOT NULL,
    window_type         TEXT NOT NULL DEFAULT '5m'
        CHECK (window_type IN ('1m', '5m', '15m', '1h', '1d')),
    total_checks        INTEGER NOT NULL DEFAULT 0,
    successful_checks   INTEGER NOT NULL DEFAULT 0,
    failed_checks       INTEGER NOT NULL DEFAULT 0,
    timeout_checks      INTEGER NOT NULL DEFAULT 0,
    error_checks        INTEGER NOT NULL DEFAULT 0,
    avg_latency_ms      DOUBLE PRECISION DEFAULT NULL,
    p50_latency_ms      DOUBLE PRECISION DEFAULT NULL,
    p95_latency_ms      DOUBLE PRECISION DEFAULT NULL,
    p99_latency_ms      DOUBLE PRECISION DEFAULT NULL,
    uptime_pct          DOUBLE PRECISION GENERATED ALWAYS AS
        (CASE
            WHEN total_checks > 0
            THEN ROUND((successful_checks::DOUBLE PRECISION / total_checks) * 100, 2)
            ELSE 0.0
        END) STORED,
    health_status       cluster_health_status NOT NULL DEFAULT 'unknown',
    score_metadata      JSONB DEFAULT '{}'::jsonb,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (id, window_start)
) PARTITION BY RANGE (window_start);

-- Bootstrap partitions
CREATE TABLE IF NOT EXISTS cluster_health_scores_2026_06
    PARTITION OF cluster_health_scores
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE IF NOT EXISTS cluster_health_scores_2026_07
    PARTITION OF cluster_health_scores
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE IF NOT EXISTS cluster_health_scores_2026_08
    PARTITION OF cluster_health_scores
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');

-- Indexes for health scores
CREATE INDEX idx_health_scores_cluster_window
    ON cluster_health_scores(cluster_id, window_start DESC);
CREATE INDEX idx_health_scores_status
    ON cluster_health_scores(health_status, window_start DESC);
CREATE INDEX idx_health_scores_window_brin
    ON cluster_health_scores USING BRIN (window_start)
    WITH (pages_per_range = 32);
CREATE UNIQUE INDEX idx_health_scores_cluster_window_unique
    ON cluster_health_scores(cluster_id, window_start, window_type);

-- ============================================================================
-- 7. Cluster Connectivity Status (Live Current State)
-- ============================================================================
-- Denormalized table holding the current status for each cluster.
-- Updated on every health check completion and heartbeat receipt.
-- Powers the "live" indicator on the dashboard.
CREATE TABLE IF NOT EXISTS cluster_connectivity_status (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster_id              UUID NOT NULL UNIQUE
                            REFERENCES cluster_connections(id) ON DELETE CASCADE,
    health_status           cluster_health_status NOT NULL DEFAULT 'unknown',
    is_reachable            BOOLEAN NOT NULL DEFAULT FALSE,
    last_heartbeat_at       TIMESTAMPTZ DEFAULT NULL,
    last_check_at           TIMESTAMPTZ DEFAULT NULL,
    last_success_at         TIMESTAMPTZ DEFAULT NULL,
    last_failure_at         TIMESTAMPTZ DEFAULT NULL,
    consecutive_failures    INTEGER NOT NULL DEFAULT 0,
    current_latency_ms      DOUBLE PRECISION DEFAULT NULL,
    avg_latency_5m_ms       DOUBLE PRECISION DEFAULT NULL,
    uptime_24h_pct          DOUBLE PRECISION DEFAULT NULL,
    uptime_7d_pct           DOUBLE PRECISION DEFAULT NULL,
    certificate_status      TEXT DEFAULT NULL
                            CHECK (certificate_status IN ('valid', 'expiring_soon', 'expired', 'unknown')),
    days_until_cert_expiry  INTEGER DEFAULT NULL,
    last_error_message      TEXT DEFAULT NULL,
    agent_version           TEXT DEFAULT NULL,
    node_count              INTEGER DEFAULT NULL,
    pod_count               INTEGER DEFAULT NULL,
    status_metadata         JSONB DEFAULT '{}'::jsonb,
    last_updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT valid_latency
        CHECK (current_latency_ms IS NULL OR current_latency_ms >= 0),
    CONSTRAINT valid_consecutive_failures
        CHECK (consecutive_failures >= 0)
);

-- Indexes for connectivity status
CREATE INDEX idx_connectivity_status_health
    ON cluster_connectivity_status(health_status)
    WHERE health_status IN ('degraded', 'unhealthy');
CREATE INDEX idx_connectivity_status_reachable
    ON cluster_connectivity_status(is_reachable)
    WHERE is_reachable = FALSE;
CREATE INDEX idx_connectivity_status_certificate
    ON cluster_connectivity_status(certificate_status)
    WHERE certificate_status IN ('expiring_soon', 'expired');
CREATE INDEX idx_connectivity_status_last_heartbeat
    ON cluster_connectivity_status(last_heartbeat_at)
    WHERE last_heartbeat_at IS NOT NULL;
CREATE INDEX idx_connectivity_status_metadata
    ON cluster_connectivity_status USING GIN (status_metadata jsonb_path_ops);

-- Trigger for auto-updating updated_at
CREATE TRIGGER update_cluster_connectivity_status_modtime
    BEFORE UPDATE ON cluster_connectivity_status
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

-- ============================================================================
-- 8. Functions & Triggers for Status Propagation
-- ============================================================================

-- --------------------------------------------------------------------------
-- 8a. Function: Update cluster connectivity status on new check result
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_update_connectivity_on_check_result()
RETURNS TRIGGER AS $$
DECLARE
    consecutive_fail INTEGER;
    last_error TEXT;
    threshold INTEGER;
BEGIN
    -- Get the health threshold from config
    SELECT cc.health_threshold INTO threshold
    FROM connectivity_check_config cc
    WHERE cc.id = NEW.check_config_id;

    -- Determine consecutive failures
    IF NEW.result = 'success' THEN
        consecutive_fail := 0;
        last_error := NULL;
    ELSE
        SELECT COALESCE(ccs.consecutive_failures, 0) + 1 INTO consecutive_fail
        FROM cluster_connectivity_status ccs
        WHERE ccs.cluster_id = NEW.cluster_id;
        last_error := NEW.error_message;
    END IF;

    -- Upsert into connectivity status
    INSERT INTO cluster_connectivity_status (
        cluster_id,
        health_status,
        is_reachable,
        last_check_at,
        last_success_at,
        last_failure_at,
        consecutive_failures,
        current_latency_ms,
        last_error_message,
        last_updated_at,
        status_metadata
    ) VALUES (
        NEW.cluster_id,
        CASE
            WHEN NEW.result = 'success' THEN 'healthy'
            WHEN consecutive_fail >= COALESCE(threshold, 3) THEN 'unhealthy'
            WHEN consecutive_fail > 0 THEN 'degraded'
            ELSE 'unknown'
        END,
        (NEW.result = 'success'),
        NEW.checked_at,
        CASE WHEN NEW.result = 'success' THEN NEW.checked_at ELSE NULL END,
        CASE WHEN NEW.result != 'success' THEN NEW.checked_at ELSE NULL END,
        consecutive_fail,
        NEW.latency_ms,
        last_error,
        NOW(),
        jsonb_build_object('last_check_id', NEW.id, 'last_result', NEW.result::text)
    )
    ON CONFLICT (cluster_id) DO UPDATE SET
        health_status = CASE
            WHEN NEW.result = 'success' THEN 'healthy'
            WHEN EXCLUDED.consecutive_failures >= COALESCE(threshold, 3) THEN 'unhealthy'
            WHEN EXCLUDED.consecutive_failures > 0 THEN 'degraded'
            ELSE cluster_connectivity_status.health_status
        END,
        is_reachable = (NEW.result = 'success'),
        last_check_at = NEW.checked_at,
        last_success_at = CASE WHEN NEW.result = 'success' THEN NEW.checked_at ELSE cluster_connectivity_status.last_success_at END,
        last_failure_at = CASE WHEN NEW.result != 'success' THEN NEW.checked_at ELSE cluster_connectivity_status.last_failure_at END,
        consecutive_failures = consecutive_fail,
        current_latency_ms = NEW.latency_ms,
        last_error_message = CASE WHEN NEW.result != 'success' THEN NEW.error_message ELSE NULL END,
        status_metadata = cluster_connectivity_status.status_metadata || jsonb_build_object('last_check_id', NEW.id, 'last_result', NEW.result::text),
        last_updated_at = NOW(),
        updated_at = NOW();

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger on connectivity_check_results to auto-update status
CREATE TRIGGER trg_check_result_update_status
    AFTER INSERT ON connectivity_check_results
    FOR EACH ROW
    EXECUTE FUNCTION fn_update_connectivity_on_check_result();

-- --------------------------------------------------------------------------
-- 8b. Function: Update cluster connectivity status on heartbeat
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_update_connectivity_on_heartbeat()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO cluster_connectivity_status (
        cluster_id,
        last_heartbeat_at,
        agent_version,
        node_count,
        pod_count,
        status_metadata,
        last_updated_at
    ) VALUES (
        NEW.cluster_id,
        NEW.received_at,
        NEW.agent_version,
        NEW.node_count,
        NEW.pod_count,
        jsonb_build_object('last_heartbeat_id', NEW.id, 'agent_version', NEW.agent_version),
        NOW()
    )
    ON CONFLICT (cluster_id) DO UPDATE SET
        last_heartbeat_at = NEW.received_at,
        agent_version = COALESCE(NEW.agent_version, cluster_connectivity_status.agent_version),
        node_count = COALESCE(NEW.node_count, cluster_connectivity_status.node_count),
        pod_count = COALESCE(NEW.pod_count, cluster_connectivity_status.pod_count),
        status_metadata = cluster_connectivity_status.status_metadata ||
            jsonb_build_object('last_heartbeat_id', NEW.id),
        last_updated_at = NOW(),
        updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger on cluster_heartbeats to auto-update status
CREATE TRIGGER trg_heartbeat_update_status
    AFTER INSERT ON cluster_heartbeats
    FOR EACH ROW
    EXECUTE FUNCTION fn_update_connectivity_on_heartbeat();

-- --------------------------------------------------------------------------
-- 8c. Function: Auto-create connectivity status on new cluster connection
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_init_cluster_connectivity_status()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO cluster_connectivity_status (cluster_id, health_status, is_reachable)
    VALUES (NEW.id, 'unknown', FALSE)
    ON CONFLICT (cluster_id) DO NOTHING;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger on cluster_connections (from CLUSTER-01) to init status
CREATE TRIGGER trg_init_connectivity_status
    AFTER INSERT ON cluster_connections
    FOR EACH ROW
    EXECUTE FUNCTION fn_init_cluster_connectivity_status();

-- --------------------------------------------------------------------------
-- 8d. Function: Auto-create check config for new cluster connection
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_init_default_check_config()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO connectivity_check_config (
        cluster_id,
        protocol,
        endpoint,
        port,
        config_metadata
    )
    SELECT
        NEW.id,
        'https',
        c.api_endpoint,
        443,
        jsonb_build_object('auto_created', TRUE)
    FROM cluster_connections c
    WHERE c.id = NEW.id AND c.api_endpoint IS NOT NULL;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger on cluster_connections to create default check config
CREATE TRIGGER trg_init_default_check_config
    AFTER INSERT ON cluster_connections
    FOR EACH ROW
    EXECUTE FUNCTION fn_init_default_check_config();

-- ============================================================================
-- 9. pg_partman Configuration (for production partition management)
-- ============================================================================
-- Uncomment and run once pg_partman is installed:
--
-- SELECT partman.create_parent(
--     p_parent_table   := 'public.connectivity_check_results',
--     p_control        := 'checked_at',
--     p_type           := 'native',
--     p_interval       := '1 month',
--     p_premake        := 3,
--     p_start_partition := '2026-06-01'
-- );
--
-- SELECT partman.create_parent(
--     p_parent_table   := 'public.cluster_heartbeats',
--     p_control        := 'received_at',
--     p_type           := 'native',
--     p_interval       := '1 month',
--     p_premake        := 3,
--     p_start_partition := '2026-06-01'
-- );
--
-- SELECT partman.create_parent(
--     p_parent_table   := 'public.cluster_health_scores',
--     p_control        := 'window_start',
--     p_type           := 'native',
--     p_interval       := '1 month',
--     p_premake        := 3,
--     p_start_partition := '2026-06-01'
-- );
--
-- -- Set retention policy: keep 12 months of data
-- UPDATE partman.part_config SET
--     retention = '12 months',
--     retention_keep_table = FALSE,
--     infinite_time_partitions = FALSE
-- WHERE parent_table IN (
--     'public.connectivity_check_results',
--     'public.cluster_heartbeats',
--     'public.cluster_health_scores'
-- );

-- ============================================================================
-- 10. Comments & Documentation
-- ============================================================================
COMMENT ON TABLE connectivity_check_config IS
    'Defines how connectivity is verified per cluster. Supports multiple protocols.';
COMMENT ON COLUMN connectivity_check_config.health_threshold IS
    'Number of consecutive failures before marking the cluster as unhealthy.';
COMMENT ON COLUMN connectivity_check_config.config_metadata IS
    'Protocol-specific configuration: e.g., {ca_cert_path: "/etc/certs/ca.pem", headers: {"Authorization": "Bearer ..."}}';

COMMENT ON TABLE connectivity_check_results IS
    'Individual connectivity check results. Partitioned by month via pg_partman.';
COMMENT ON COLUMN connectivity_check_results.latency_ms IS
    'Round-trip latency in milliseconds. NULL if the check failed.';
COMMENT ON COLUMN connectivity_check_results.status_code IS
    'HTTP status code (for https checks) or protocol-specific status.';

COMMENT ON TABLE cluster_heartbeats IS
    'Periodic heartbeat signals from cluster agents. Partitioned by month.';
COMMENT ON COLUMN cluster_heartbeats.heartbeat_metadata IS
    'Additional telemetry: {kubernetes_version, cloud_region, instance_count, ...}';

COMMENT ON TABLE cluster_certificate_expiry IS
    'Tracks TLS certificate lifecycle for each cluster endpoint.';
COMMENT ON COLUMN cluster_certificate_expiry.days_until_expiry IS
    'Generated column: (not_after - NOW()) in days. Auto-recalculated on query.';
COMMENT ON COLUMN cluster_certificate_expiry.severity IS
    'critical (<7 days), warning (7-30 days), info (>30 days).';

COMMENT ON TABLE cluster_health_scores IS
    'Pre-aggregated health metrics per time window (1m/5m/15m/1h/1d).';
COMMENT ON COLUMN cluster_health_scores.uptime_pct IS
    'Generated column: (successful_checks / total_checks) * 100.';

COMMENT ON TABLE cluster_connectivity_status IS
    'Denormalized live connectivity status for each cluster. Updated via triggers.';
COMMENT ON COLUMN cluster_connectivity_status.days_until_cert_expiry IS
    'Lowest days_until_expiry from cluster_certificate_expiry for this cluster. Updated periodically.';

-- ============================================================================
-- END OF MIGRATION
-- ============================================================================
COMMIT;
