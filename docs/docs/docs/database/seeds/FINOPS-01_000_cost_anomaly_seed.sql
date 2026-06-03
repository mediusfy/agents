-- FINOPS-01: Seed Data for Cost Anomaly Detection
-- ==========================================================================
-- This seed script populates:
--   1. Sample cost telemetry for baseline computation (14 days × providers × regions)
--   2. Pre-computed baselines (seeded to jumpstart the system)
--   3. Sample anomaly events for dashboard testing
--   4. Suppression log entries for audit verification
-- ==========================================================================

-- +goose Up
-- +goose StatementBegin

--------------------------------------------------------------------------------
-- 1. SAMPLE COST TELEMETRY (14 days of hourly-ish data for 3 providers × 2 regions)
--------------------------------------------------------------------------------

-- Helper: Generate hourly cost data with realistic patterns
-- AWS - EU - EC2: ~$42.50/hr base with some variance
INSERT INTO finops.cost_telemetry (provider, region, service, metric_name, amount, ingested_at)
SELECT
    'AWS'::finops.provider_enum,
    'EU'::finops.region_enum,
    'EC2',
    'compute_cost',
    42.50 + (random() * 5.0) - 2.5,  -- $40-$47 range
    date_trunc('hour', NOW()) - (INTERVAL '1 hour' * (336 - n))  -- 336 hours = 14 days
FROM generate_series(0, 335) AS n;

-- AWS - US - EC2: ~$38.20/hr base
INSERT INTO finops.cost_telemetry (provider, region, service, metric_name, amount, ingested_at)
SELECT
    'AWS'::finops.provider_enum,
    'US'::finops.region_enum,
    'EC2',
    'compute_cost',
    38.20 + (random() * 4.0) - 2.0,
    date_trunc('hour', NOW()) - (INTERVAL '1 hour' * (336 - n))
FROM generate_series(0, 335) AS n;

-- GCP - EU - Compute Engine: ~$35.75/hr base
INSERT INTO finops.cost_telemetry (provider, region, service, metric_name, amount, ingested_at)
SELECT
    'GCP'::finops.provider_enum,
    'EU'::finops.region_enum,
    'Compute Engine',
    'compute_cost',
    35.75 + (random() * 3.5) - 1.75,
    date_trunc('hour', NOW()) - (INTERVAL '1 hour' * (336 - n))
FROM generate_series(0, 335) AS n;

-- GCP - US - Compute Engine: ~$31.50/hr base
INSERT INTO finops.cost_telemetry (provider, region, service, metric_name, amount, ingested_at)
SELECT
    'GCP'::finops.provider_enum,
    'US'::finops.region_enum,
    'Compute Engine',
    'compute_cost',
    31.50 + (random() * 3.0) - 1.5,
    date_trunc('hour', NOW()) - (INTERVAL '1 hour' * (336 - n))
FROM generate_series(0, 335) AS n;

-- Azure - EU - Virtual Machines: ~$48.90/hr base
INSERT INTO finops.cost_telemetry (provider, region, service, metric_name, amount, ingested_at)
SELECT
    'Azure'::finops.provider_enum,
    'EU'::finops.region_enum,
    'Virtual Machines',
    'compute_cost',
    48.90 + (random() * 6.0) - 3.0,
    date_trunc('hour', NOW()) - (INTERVAL '1 hour' * (336 - n))
FROM generate_series(0, 335) AS n;

-- Azure - US - Virtual Machines: ~$44.30/hr base
INSERT INTO finops.cost_telemetry (provider, region, service, metric_name, amount, ingested_at)
SELECT
    'Azure'::finops.provider_enum,
    'US'::finops.region_enum,
    'Virtual Machines',
    'compute_cost',
    44.30 + (random() * 5.5) - 2.75,
    date_trunc('hour', NOW()) - (INTERVAL '1 hour' * (336 - n))
FROM generate_series(0, 335) AS n;

-- Storage cost metrics (lower volume, different pattern)
INSERT INTO finops.cost_telemetry (provider, region, service, metric_name, amount, ingested_at)
SELECT
    'AWS'::finops.provider_enum,
    'EU'::finops.region_enum,
    'S3',
    'storage_cost',
    12.80 + (random() * 1.5) - 0.75,
    date_trunc('hour', NOW()) - (INTERVAL '1 hour' * (336 - n))
FROM generate_series(0, 335) AS n;

INSERT INTO finops.cost_telemetry (provider, region, service, metric_name, amount, ingested_at)
SELECT
    'AWS'::finops.provider_enum,
    'US'::finops.region_enum,
    'S3',
    'storage_cost',
    10.40 + (random() * 1.2) - 0.6,
    date_trunc('hour', NOW()) - (INTERVAL '1 hour' * (336 - n))
FROM generate_series(0, 335) AS n;

-- Network cost metrics
INSERT INTO finops.cost_telemetry (provider, region, service, metric_name, amount, ingested_at)
SELECT
    'GCP'::finops.provider_enum,
    'EU'::finops.region_enum,
    'Cloud CDN',
    'network_cost',
    8.25 + (random() * 2.0) - 1.0,
    date_trunc('hour', NOW()) - (INTERVAL '1 hour' * (336 - n))
FROM generate_series(0, 335) AS n;

--------------------------------------------------------------------------------
-- 2. PRE-COMPUTED BASELINES (jumpstart the detection engine)
--------------------------------------------------------------------------------

INSERT INTO finops.cost_baselines
    (provider, region, service, metric_name, mean_cost, stddev_cost, threshold_multiplier,
     baseline_start, baseline_end, sample_count, computed_at)
VALUES
    -- AWS
    ('AWS', 'EU', 'EC2',              'compute_cost',  42.50, 1.44, 3.00,
     NOW() - INTERVAL '7 days', NOW(), 168, NOW()),
    ('AWS', 'US', 'EC2',              'compute_cost',  38.20, 1.15, 3.00,
     NOW() - INTERVAL '7 days', NOW(), 168, NOW()),
    ('AWS', 'EU', 'S3',               'storage_cost',  12.80, 0.43, 3.00,
     NOW() - INTERVAL '7 days', NOW(), 168, NOW()),
    ('AWS', 'US', 'S3',               'storage_cost',  10.40, 0.35, 3.00,
     NOW() - INTERVAL '7 days', NOW(), 168, NOW()),

    -- GCP
    ('GCP', 'EU', 'Compute Engine',   'compute_cost',  35.75, 1.01, 3.00,
     NOW() - INTERVAL '7 days', NOW(), 168, NOW()),
    ('GCP', 'US', 'Compute Engine',   'compute_cost',  31.50, 0.87, 3.00,
     NOW() - INTERVAL '7 days', NOW(), 168, NOW()),
    ('GCP', 'EU', 'Cloud CDN',        'network_cost',   8.25, 0.58, 3.00,
     NOW() - INTERVAL '7 days', NOW(), 168, NOW()),

    -- Azure
    ('Azure', 'EU', 'Virtual Machines', 'compute_cost', 48.90, 1.73, 3.00,
     NOW() - INTERVAL '7 days', NOW(), 168, NOW()),
    ('Azure', 'US', 'Virtual Machines', 'compute_cost', 44.30, 1.58, 3.00,
     NOW() - INTERVAL '7 days', NOW(), 168, NOW())
ON CONFLICT (provider, region, service, metric_name) DO NOTHING;

--------------------------------------------------------------------------------
-- 3. SAMPLE ANOMALY EVENTS (for dashboard testing)
--------------------------------------------------------------------------------

-- A recent anomaly for AWS EU EC2 (spike above threshold)
INSERT INTO finops.cost_anomaly_events
    (provider, region, service, metric_name, telemetry_id, baseline_id,
     observed_cost, expected_cost, projected_monthly_impact,
     threshold_multiplier, status, detected_at, metadata)
SELECT
    'AWS'::finops.provider_enum,
    'EU'::finops.region_enum,
    'EC2', 'compute_cost',
    (SELECT id FROM finops.cost_telemetry WHERE provider = 'AWS' AND region = 'EU' AND service = 'EC2' ORDER BY ingested_at DESC LIMIT 1),
    (SELECT id FROM finops.cost_baselines WHERE provider = 'AWS' AND region = 'EU' AND service = 'EC2' AND metric_name = 'compute_cost' LIMIT 1),
    185.40,  -- observed (well above threshold)
    42.50,   -- expected mean
    104,317.00,  -- projected monthly impact = (185.40 - 42.50) * 730
    3.00,
    'new',
    NOW() - INTERVAL '30 minutes',
    '{"source": "seed_data", "instance_type": "c5.4xlarge", "region_name": "eu-west-1"}'::jsonb;

-- A recent anomaly for GCP US (smaller spike)
INSERT INTO finops.cost_anomaly_events
    (provider, region, service, metric_name, telemetry_id, baseline_id,
     observed_cost, expected_cost, projected_monthly_impact,
     threshold_multiplier, status, detected_at, metadata)
SELECT
    'GCP'::finops.provider_enum,
    'US'::finops.region_enum,
    'Compute Engine', 'compute_cost',
    (SELECT id FROM finops.cost_telemetry WHERE provider = 'GCP' AND region = 'US' AND service = 'Compute Engine' ORDER BY ingested_at DESC LIMIT 1),
    (SELECT id FROM finops.cost_baselines WHERE provider = 'GCP' AND region = 'US' AND service = 'Compute Engine' AND metric_name = 'compute_cost' LIMIT 1),
    95.20,
    31.50,
    46,501.00,
    3.00,
    'acknowledged',
    NOW() - INTERVAL '3 hours',
    '{"source": "seed_data", "instance_type": "n2-standard-8", "region_name": "us-central1"}'::jsonb;

-- A resolved anomaly for Azure EU
INSERT INTO finops.cost_anomaly_events
    (provider, region, service, metric_name, telemetry_id, baseline_id,
     observed_cost, expected_cost, projected_monthly_impact,
     threshold_multiplier, status, detected_at, acknowledged_at, resolved_at, metadata)
SELECT
    'Azure'::finops.provider_enum,
    'EU'::finops.region_enum,
    'Virtual Machines', 'compute_cost',
    (SELECT id FROM finops.cost_telemetry WHERE provider = 'Azure' AND region = 'EU' AND service = 'Virtual Machines' ORDER BY ingested_at DESC LIMIT 1),
    (SELECT id FROM finops.cost_baselines WHERE provider = 'Azure' AND region = 'EU' AND service = 'Virtual Machines' AND metric_name = 'compute_cost' LIMIT 1),
    210.75,
    48.90,
    118,150.50,
    3.00,
    'resolved',
    NOW() - INTERVAL '24 hours',
    NOW() - INTERVAL '20 hours',
    NOW() - INTERVAL '18 hours',
    '{"source": "seed_data", "instance_type": "Standard_D8s_v5", "region_name": "westeurope", "resolution": "scaled down excess capacity"}'::jsonb;

-- A suppressed anomaly (would have been duplicate within 1hr window)
INSERT INTO finops.cost_anomaly_events
    (provider, region, service, metric_name, telemetry_id, baseline_id,
     observed_cost, expected_cost, projected_monthly_impact,
     threshold_multiplier, status, suppressed, suppression_reason, detected_at, metadata)
SELECT
    'AWS'::finops.provider_enum,
    'EU'::finops.region_enum,
    'EC2', 'compute_cost',
    (SELECT id FROM finops.cost_telemetry WHERE provider = 'AWS' AND region = 'EU' AND service = 'EC2' ORDER BY ingested_at DESC LIMIT 1 OFFSET 1),
    (SELECT id FROM finops.cost_baselines WHERE provider = 'AWS' AND region = 'EU' AND service = 'EC2' AND metric_name = 'compute_cost' LIMIT 1),
    178.20,
    42.50,
    99,061.00,
    3.00,
    'suppressed', TRUE,
    'Duplicate anomaly within 1-hour suppression window',
    NOW() - INTERVAL '15 minutes',
    '{"source": "seed_data", "duplicate": true}'::jsonb;

-- Log the suppression
INSERT INTO finops.anomaly_suppression_log
    (original_anomaly_id, duplicate_fingerprint, duplicate_count,
     suppression_window_start, suppression_window_end, reason)
SELECT
    id,
    MD5('AWS|EU|EC2|compute_cost'),
    2,
    NOW() - INTERVAL '1 hour',
    NOW(),
    'Duplicate anomaly within 1-hour suppression window'
FROM finops.cost_anomaly_events
WHERE suppressed = TRUE
LIMIT 1;

-- +goose StatementEnd
