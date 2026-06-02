-- Seed data: 011_clusterconnect_02_seed.sql
-- Story: CLUSTERCONNECT-02 — View connected clusters with connection status indicators
-- Description: Seeds the cluster_connections and cluster_health_checks tables with
--              realistic sample data demonstrating various connection statuses.

-- =============================================================================
-- Seed cluster_connections
-- =============================================================================

WITH cluster_data AS (
    SELECT * FROM (VALUES
        ('prod-us-east',       'prod-us-east',       'Production — US East (GCP us-east1)',            'https://api.prod-us-east.example.com',   'https://dashboard.prod-us-east.example.com',  'us-east1',       'gcp',   '1.28.5',   'CONNECTED'::cluster_connection_status,    'All systems operational',                        NOW() - INTERVAL '10 seconds', NOW() - INTERVAL '1 day', 0,  '{"env": "production", "team": "platform", "tier": "critical"}'::JSONB),
        ('prod-eu-west',       'prod-eu-west',       'Production — EU West (AWS eu-west-1)',           'https://api.prod-eu-west.example.com',   'https://console.aws.amazon.com/eks/clusters/prod-eu-west', 'eu-west-1',      'aws',   '1.27.3',   'CONNECTED'::cluster_connection_status,    'All systems operational',                        NOW() - INTERVAL '30 seconds', NOW() - INTERVAL '2 days', 0,  '{"env": "production", "team": "platform", "tier": "critical"}'::JSONB),
        ('staging-us-central', 'staging-us-central', 'Staging — US Central (Azure centralus)',         'https://api.staging-us-central.example.com', NULL,                                                   'centralus',      'azure', '1.28.2',   'CONNECTED'::cluster_connection_status,    'Running normally',                               NOW() - INTERVAL '2 minutes', NOW() - INTERVAL '3 days', 0,  '{"env": "staging", "team": "devops", "tier": "standard"}'::JSONB),
        ('dev-us-west',        'dev-us-west',        'Development — US West (GCP us-west2)',           'https://api.dev-us-west.example.com',    'https://dashboard.dev-us-west.example.com',       'us-west2',       'gcp',   '1.29.0',   'DEGRADED'::cluster_connection_status,    'High latency — average response 2.4s',          NOW() - INTERVAL '1 minute', NOW() - INTERVAL '30 minutes', 2,  '{"env": "development", "team": "engineering"}'::JSONB),
        ('prod-ap-southeast',  'prod-ap-southeast',  'Production — AP Southeast (AWS ap-southeast-1)', 'https://api.prod-ap-southeast.example.com', NULL,                                                   'ap-southeast-1',  'aws',   '1.27.6',   'DEGRADED'::cluster_connection_status,    'Partial connectivity — 2/3 nodes reachable',     NOW() - INTERVAL '5 minutes', NOW() - INTERVAL '15 minutes', 3,  '{"env": "production", "team": "platform", "tier": "critical"}'::JSONB),
        ('dr-eu-central',      'dr-eu-central',      'DR — EU Central (on-prem)',                      'https://api.dr-eu-central.internal',     'https://dr-dashboard.internal',                     'eu-central-1',   'on-prem', '1.26.9',   'DISCONNECTED'::cluster_connection_status, 'Planned maintenance until 2026-06-05 02:00 UTC', NULL,                                                  NOW() - INTERVAL '2 hours', 0,  '{"env": "dr", "team": "infra", "tier": "critical"}'::JSONB),
        ('prod-sa-east',       'prod-sa-east',       'Production — SA East (AWS sa-east-1)',           'https://api.prod-sa-east.example.com',   NULL,                                                   'sa-east-1',      'aws',   '1.27.4',   'UNREACHABLE'::cluster_connection_status, 'Connection timeout — no response in 30s',        NULL,                                                  NOW() - INTERVAL '4 hours', 5,  '{"env": "production", "team": "platform", "tier": "standard"}'::JSONB),
        ('sandbox',            'sandbox',            'Sandbox — Ephemeral testing cluster',            'https://api.sandbox.example.com',        NULL,                                                   'us-east1',       'gcp',   '1.28.5',   'PENDING'::cluster_connection_status,     'Awaiting first health check',                    NULL,                                                  NOW() - INTERVAL '5 days', 0,  '{"env": "sandbox", "team": "engineering"}'::JSONB)
    ) AS t(name, slug, description, api_endpoint, dashboard_url, region, provider, version, connection_status, status_message, last_ping_at, last_status_change, consecutive_failures, labels)
)
INSERT INTO cluster_connections (name, slug, description, api_endpoint, dashboard_url, region, provider, version, connection_status, status_message, last_ping_at, last_status_change, consecutive_failures, labels)
SELECT name, slug, description, api_endpoint, dashboard_url, region, provider, version, connection_status, status_message, last_ping_at, last_status_change, consecutive_failures, labels
FROM cluster_data
ON CONFLICT (slug) DO UPDATE SET
    connection_status = EXCLUDED.connection_status,
    status_message = EXCLUDED.status_message,
    last_ping_at = EXCLUDED.last_ping_at,
    last_status_change = EXCLUDED.last_status_change,
    consecutive_failures = EXCLUDED.consecutive_failures,
    labels = EXCLUDED.labels,
    updated_at = NOW();

-- =============================================================================
-- Seed cluster_health_checks (last 24h of check data for each cluster)
-- =============================================================================

WITH connected_clusters AS (
    SELECT id, connection_status FROM cluster_connections WHERE is_active = TRUE
),
health_data AS (
    SELECT
        cc.id AS cluster_id,
        cc.connection_status AS status,
        CASE
            WHEN cc.connection_status = 'CONNECTED' THEN floor(random() * 150 + 20)::INTEGER
            WHEN cc.connection_status = 'DEGRADED' THEN floor(random() * 3000 + 500)::INTEGER
            ELSE NULL
        END AS response_time_ms,
        CASE
            WHEN cc.connection_status IN ('CONNECTED', 'DEGRADED') THEN 200::SMALLINT
            ELSE NULL
        END AS http_status_code,
        CASE
            WHEN cc.connection_status = 'DISCONNECTED' THEN 'Connection refused — cluster undergoing maintenance'
            WHEN cc.connection_status = 'UNREACHABLE' THEN 'dial tcp: i/o timeout'
            ELSE NULL
        END AS error_message,
        'scheduler'::VARCHAR AS check_source,
        generate_series(
            NOW() - INTERVAL '24 hours',
            CASE
                WHEN cc.connection_status = 'DISCONNECTED' THEN NOW() - INTERVAL '2 hours'
                WHEN cc.connection_status = 'UNREACHABLE' THEN NOW() - INTERVAL '4 hours'
                ELSE NOW()
            END,
            INTERVAL '5 minutes'
        ) AS checked_at
    FROM connected_clusters cc
)
INSERT INTO cluster_health_checks (cluster_id, status, response_time_ms, http_status_code, error_message, check_source, checked_at)
SELECT cluster_id, status, response_time_ms, http_status_code, error_message, check_source, checked_at
FROM health_data
ORDER BY checked_at DESC;

-- Verify the seeded data (uncomment to run)
-- SELECT * FROM v_cluster_list_with_health ORDER BY status_indicator, name;
