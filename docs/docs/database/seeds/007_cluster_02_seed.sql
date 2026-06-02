-- ============================================================================
-- Seed Data for CLUSTER-02: Connectivity Health Monitoring
-- ============================================================================
-- This script seeds the following tables with realistic demo data:
--   connectivity_check_config
--   connectivity_check_results
--   cluster_heartbeats
--   cluster_certificate_expiry
--   cluster_health_scores
--
-- Requires: Existing clusters in cluster_connections (CLUSTER-01 seed)
-- ============================================================================

-- Helper: Create demo clusters if they don't exist (for standalone seeding)
-- In production, clusters should already exist from CLUSTER-01 seed.
-- This is a safety net for development environments.

-- ============================================================================
-- 1. Connectivity Check Configurations
-- ============================================================================
INSERT INTO connectivity_check_config (id, cluster_id, protocol, endpoint, port, check_interval_secs, timeout_ms, retry_count, health_threshold, config_metadata, is_active)
SELECT
    gen_random_uuid(),
    c.id,
    'https',
    c.api_endpoint,
    443,
    30,
    5000,
    3,
    3,
    jsonb_build_object('auto_created', TRUE, 'environment', 'production'),
    TRUE
FROM cluster_connections c
WHERE c.deleted_at IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM connectivity_check_config cc
    WHERE cc.cluster_id = c.id AND cc.deleted_at IS NULL
  )
LIMIT 20;

-- Add gRPC check config for select clusters
INSERT INTO connectivity_check_config (id, cluster_id, protocol, endpoint, port, check_interval_secs, timeout_ms, config_metadata)
SELECT
    gen_random_uuid(),
    c.id,
    'grpc',
    REPLACE(c.api_endpoint, 'https://', ''),
    443,
    60,
    3000,
    jsonb_build_object('auto_created', TRUE, 'service', 'kube-apiserver')
FROM cluster_connections c
WHERE c.deleted_at IS NULL
  AND c.cloud_provider IN ('gcp', 'aws')
LIMIT 10;

-- ============================================================================
-- 2. Seed Recent Connectivity Check Results (last 24 hours)
-- ============================================================================
WITH recent_hours AS (
    SELECT generate_series(
        NOW() - INTERVAL '24 hours',
        NOW(),
        INTERVAL '5 minutes'
    ) AS check_time
),
cluster_list AS (
    SELECT id AS cluster_id FROM cluster_connections WHERE deleted_at IS NULL LIMIT 10
),
check_configs AS (
    SELECT cc.id AS config_id, cc.cluster_id
    FROM connectivity_check_config cc
    WHERE cc.deleted_at IS NULL
)
INSERT INTO connectivity_check_results (id, check_config_id, cluster_id, result, latency_ms, status_code, checked_at)
SELECT
    gen_random_uuid(),
    cc.config_id,
    cc.cluster_id,
    CASE
        WHEN RANDOM() < 0.92 THEN 'success'::check_result_type        -- 92% success
        WHEN RANDOM() < 0.06 THEN 'failure'::check_result_type        -- 6% failure
        WHEN RANDOM() < 0.015 THEN 'timeout'::check_result_type       -- 1.5% timeout
        ELSE 'error'::check_result_type                                -- 0.5% error
    END AS result,
    CASE
        WHEN RANDOM() < 0.92 THEN ROUND((RANDOM() * 200 + 10)::numeric, 2)
        ELSE NULL
    END AS latency_ms,
    CASE
        WHEN RANDOM() < 0.95 THEN 200
        WHEN RANDOM() < 0.98 THEN 401
        WHEN RANDOM() < 0.99 THEN 503
        ELSE 500
    END AS status_code,
    rh.check_time
FROM recent_hours rh
CROSS JOIN cluster_list cl
JOIN check_configs cc ON cc.cluster_id = cl.cluster_id
WHERE RANDOM() < 0.3  -- Not every check fires at every interval
ORDER BY rh.check_time
LIMIT 5000;

-- Add some failure spikes for demo purposes
INSERT INTO connectivity_check_results (id, check_config_id, cluster_id, result, latency_ms, status_code, error_message, checked_at)
SELECT
    gen_random_uuid(),
    cc.id,
    cc.cluster_id,
    'timeout'::check_result_type,
    NULL,
    NULL,
    'Connection timed out after 5000ms',
    NOW() - INTERVAL '2 hours' + (INTERVAL '30 seconds' * gs)
FROM connectivity_check_config cc
CROSS JOIN generate_series(0, 5, 1) gs
WHERE cc.cluster_id IN (
    SELECT id FROM cluster_connections WHERE deleted_at IS NULL AND cloud_provider = 'aws' LIMIT 1
);

-- ============================================================================
-- 3. Seed Cluster Heartbeats (last 7 days)
-- ============================================================================
WITH recent_hours AS (
    SELECT generate_series(
        NOW() - INTERVAL '7 days',
        NOW(),
        INTERVAL '1 minute'
    ) AS heartbeat_time
),
cluster_list AS (
    SELECT id AS cluster_id, name FROM cluster_connections WHERE deleted_at IS NULL LIMIT 10
)
INSERT INTO cluster_heartbeats (id, cluster_id, agent_version, node_count, pod_count, cpu_usage_pct, memory_usage_pct, heartbeat_metadata, received_at)
SELECT
    gen_random_uuid(),
    cl.cluster_id,
    'rufkis-agent/1.2.3',
    3 + (RANDOM() * 10)::INT,
    20 + (RANDOM() * 100)::INT,
    ROUND((RANDOM() * 80 + 10)::numeric, 1),
    ROUND((RANDOM() * 70 + 20)::numeric, 1),
    jsonb_build_object(
        'kubernetes_version', '1.28.3',
        'cloud_region', CASE
            WHEN cl.name LIKE '%prod%' THEN 'us-east1'
            WHEN cl.name LIKE '%staging%' THEN 'us-central1'
            ELSE 'europe-west1'
        END,
        'instance_type', 'n2-standard-4'
    ),
    rh.heartbeat_time
FROM recent_hours rh
CROSS JOIN cluster_list cl
ORDER BY rh.heartbeat_time
LIMIT 50000;

-- ============================================================================
-- 4. Seed Certificate Expiry Data
-- ============================================================================
INSERT INTO cluster_certificate_expiry (id, cluster_id, common_name, issuer, serial_number, fingerprint_sha256, not_before, not_after, severity, cert_metadata)
SELECT
    gen_random_uuid(),
    c.id,
    CASE
        WHEN c.name LIKE '%prod%' THEN '*.production.example.com'
        WHEN c.name LIKE '%staging%' THEN '*.staging.example.com'
        ELSE '*.dev.example.com'
    END,
    'Rufkis Internal CA',
    LPAD(TO_HEX((RANDOM() * 16777215)::INT), 8, '0') || LPAD(TO_HEX((RANDOM() * 16777215)::INT), 8, '0'),
    ENCODE(DECODE(MD5(RANDOM()::TEXT), 'hex'), 'hex'),
    NOW() - INTERVAL '180 days',
    CASE
        WHEN RANDOM() < 0.7 THEN NOW() + INTERVAL '90 days'   -- Valid
        WHEN RANDOM() < 0.15 THEN NOW() + INTERVAL '20 days'  -- Warning
        WHEN RANDOM() < 0.1 THEN NOW() + INTERVAL '5 days'    -- Critical
        ELSE NOW() - INTERVAL '10 days'                        -- Expired
    END,
    CASE
        WHEN RANDOM() < 0.7 THEN 'info'::certificate_severity
        WHEN RANDOM() < 0.15 THEN 'warning'::certificate_severity
        WHEN RANDOM() < 0.1 THEN 'critical'::certificate_severity
        ELSE 'critical'::certificate_severity
    END,
    jsonb_build_object(
        'san', jsonb_build_array(
            CASE WHEN c.name LIKE '%prod%' THEN 'production.example.com' ELSE '*.example.com' END,
            CASE WHEN c.name LIKE '%prod%' THEN '*.production.example.com' ELSE '*.dev.example.com' END
        ),
        'key_algorithm', 'RSA-2048',
        'signature_algorithm', 'SHA256-RSA'
    )
FROM cluster_connections c
WHERE c.deleted_at IS NULL
LIMIT 30;

-- ============================================================================
-- 5. Seed Health Score Aggregations (last 48 hours, 5-minute windows)
-- ============================================================================
WITH time_windows AS (
    SELECT generate_series(
        NOW() - INTERVAL '48 hours',
        NOW(),
        INTERVAL '5 minutes'
    ) AS window_start
),
cluster_list AS (
    SELECT id AS cluster_id FROM cluster_connections WHERE deleted_at IS NULL LIMIT 10
)
INSERT INTO cluster_health_scores (id, cluster_id, window_start, window_end, window_type, total_checks, successful_checks, failed_checks, timeout_checks, error_checks, avg_latency_ms, p50_latency_ms, p95_latency_ms, p99_latency_ms, health_status)
SELECT
    gen_random_uuid(),
    cl.cluster_id,
    tw.window_start,
    tw.window_start + INTERVAL '5 minutes',
    '5m',
    total::INT,
    successful::INT,
    failed::INT,
    timeouts::INT,
    errors::INT,
    avg_lat,
    p50_lat,
    p95_lat,
    p99_lat,
    CASE
        WHEN successful = total AND total > 0 THEN 'healthy'::cluster_health_status
        WHEN successful::FLOAT / NULLIF(total, 0) >= 0.95 THEN 'healthy'::cluster_health_status
        WHEN successful::FLOAT / NULLIF(total, 0) >= 0.80 THEN 'degraded'::cluster_health_status
        WHEN total > 0 THEN 'unhealthy'::cluster_health_status
        ELSE 'unknown'::cluster_health_status
    END
FROM time_windows tw
CROSS JOIN cluster_list cl
CROSS JOIN LATERAL (
    SELECT
        6 AS total,
        5 AS successful,
        1 AS failed,
        0 AS timeouts,
        0 AS errors,
        45.2 AS avg_lat,
        42.0 AS p50_lat,
        120.0 AS p95_lat,
        200.0 AS p99_lat
) stats
WHERE RANDOM() < 0.5
ORDER BY tw.window_start
LIMIT 2000;

-- ============================================================================
-- 6. Initialize Connectivity Status (for any clusters that don't have one)
-- ============================================================================
INSERT INTO cluster_connectivity_status (id, cluster_id, health_status, is_reachable)
SELECT
    gen_random_uuid(),
    c.id,
    CASE
        WHEN RANDOM() < 0.8 THEN 'healthy'
        WHEN RANDOM() < 0.1 THEN 'degraded'
        WHEN RANDOM() < 0.05 THEN 'unhealthy'
        ELSE 'unknown'
    END,
    (RANDOM() < 0.95)
FROM cluster_connections c
WHERE c.deleted_at IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM cluster_connectivity_status cs
    WHERE cs.cluster_id = c.id
  )
LIMIT 20;

-- Update connectivity status with latest data from other tables
UPDATE cluster_connectivity_status ccs
SET
    last_heartbeat_at = hb.last_hb,
    last_check_at = cr.last_check,
    last_success_at = cr.last_success,
    last_failure_at = cr.last_failure,
    consecutive_failures = cr.fail_count,
    current_latency_ms = cr.last_latency,
    node_count = hb.node_count,
    pod_count = hb.pod_count,
    agent_version = hb.agent_ver,
    days_until_cert_expiry = ce.min_days,
    certificate_status = CASE
        WHEN ce.min_days IS NULL THEN 'unknown'
        WHEN ce.min_days < 0 THEN 'expired'
        WHEN ce.min_days <= 7 THEN 'expiring_soon'
        ELSE 'valid'
    END,
    last_updated_at = NOW()
FROM (
    SELECT DISTINCT ON (cluster_id)
        cluster_id,
        received_at AS last_hb,
        node_count,
        pod_count,
        agent_version AS agent_ver
    FROM cluster_heartbeats
    ORDER BY cluster_id, received_at DESC
) hb
LEFT JOIN (
    SELECT
        cluster_id,
        MAX(checked_at) AS last_check,
        MAX(checked_at) FILTER (WHERE result = 'success') AS last_success,
        MAX(checked_at) FILTER (WHERE result != 'success') AS last_failure,
        COUNT(*) FILTER (WHERE result IN ('failure', 'timeout', 'error')) AS fail_count,
        (SELECT latency_ms FROM connectivity_check_results cr2
         WHERE cr2.cluster_id = cr.cluster_id AND cr2.result = 'success'
         ORDER BY checked_at DESC LIMIT 1) AS last_latency
    FROM connectivity_check_results cr
    GROUP BY cluster_id
) cr ON cr.cluster_id = ccs.cluster_id
LEFT JOIN (
    SELECT
        cluster_id,
        MIN(days_until_expiry) AS min_days
    FROM cluster_certificate_expiry
    WHERE deleted_at IS NULL AND is_renewed = FALSE
    GROUP BY cluster_id
) ce ON ce.cluster_id = ccs.cluster_id
WHERE ccs.cluster_id = hb.cluster_id;

-- ============================================================================
-- END OF SEED SCRIPT
-- ============================================================================
