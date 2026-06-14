-- Seed Data: ENTITYMGMT-12_000_app_startup_lifecycle_seed.sql
-- Story: ENTITYMGMT-12 — Application startup lifecycle seed data
-- Bounded Context: Entity Management
--
-- Prerequisites:
--   - ENTITYMGMT-12_000_app_startup_lifecycle.up.sql applied
--
-- ============================================================================
-- This seed script populates:
--   1. app_startup_events — Simulated startup history for development/testing
--   2. app_deployments — Deployment records for version tracking
--   3. otel_metrics_config — Already seeded in up.sql, but we add test variants
--
-- The seed data enables development teams to test:
--   - /healthz and /readyz endpoints with actual startup history
--   - get_latest_successful_startup() returns the "latest" record
--   - get_last_startup_failure() returns failure diagnostics
--   - count_recent_startup_failures() crash-loop detection
--   - get_startup_metrics() aggregate dashboard queries
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. Seed: app_startup_events
-- ============================================================================
-- We create a realistic startup history:
--   - 2 successful startups (simulating 2 pod restarts)
--   - 1 failed startup (simulating a crash loop scenario)
-- ============================================================================

-- Simulate: First successful startup (e.g., initial deployment)
INSERT INTO app_startup_events (
    id, service_name, service_version, region, hostname, pid,
    deployment_id, status, stage, latest_migration_id,
    latest_migration_number, startup_started_at, startup_completed_at,
    startup_duration_ms, outbox_event_id, created_at, updated_at
) VALUES (
    'a0000001-0000-4000-8000-000000000001',
    'entity-management', '1.0.0', 'eu-west-1', 'pod-entity-mgmt-5f7c9d8b6c-x4h3k', 42,
    'deploy-gha-184729', 'running', 'http_server', 'ENTITYMGMT-12', 12,
    NOW() - INTERVAL '10 minutes' - INTERVAL '3 seconds',
    NOW() - INTERVAL '10 minutes',
    3200,
    'o0000001-0000-4000-8000-000000000001',
    NOW() - INTERVAL '10 minutes',
    NOW() - INTERVAL '10 minutes'
)
ON CONFLICT (id) DO NOTHING;

-- Simulate: Failed startup (database connection failure)
INSERT INTO app_startup_events (
    id, service_name, service_version, region, hostname, pid,
    status, stage, latest_migration_id, latest_migration_number,
    error_message, error_stage,
    startup_started_at, startup_completed_at,
    outbox_event_id, created_at, updated_at
) VALUES (
    'a0000002-0000-4000-8000-000000000002',
    'entity-management', '1.0.0', 'eu-west-1', 'pod-entity-mgmt-5f7c9d8b6c-x4h3k', 43,
    'failed', 'database_connection', 'ENTITYMGMT-12', 12,
    'connection refused: dial tcp 10.0.0.1:5432: connect: connection refused',
    'database_connection',
    NOW() - INTERVAL '5 minutes' - INTERVAL '500 milliseconds',
    NOW() - INTERVAL '5 minutes',
    'o0000002-0000-4000-8000-000000000002',
    NOW() - INTERVAL '5 minutes',
    NOW() - INTERVAL '5 minutes'
)
ON CONFLICT (id) DO NOTHING;

-- Simulate: Second successful startup (after recovery/restart)
INSERT INTO app_startup_events (
    id, service_name, service_version, region, hostname, pid,
    deployment_id, status, stage, latest_migration_id,
    latest_migration_number, startup_started_at, startup_completed_at,
    startup_duration_ms, outbox_event_id, created_at, updated_at
) VALUES (
    'a0000003-0000-4000-8000-000000000003',
    'entity-management', '1.0.1', 'eu-west-1', 'pod-entity-mgmt-5f7c9d8b6c-y9j2m', 44,
    'deploy-gha-184730', 'running', 'http_server', 'ENTITYMGMT-12', 12,
    NOW() - INTERVAL '2 minutes' - INTERVAL '2.5 seconds',
    NOW() - INTERVAL '2 minutes',
    2500,
    'o0000003-0000-4000-8000-000000000003',
    NOW() - INTERVAL '2 minutes',
    NOW() - INTERVAL '2 minutes'
)
ON CONFLICT (id) DO NOTHING;

-- ============================================================================
-- 2. Seed: app_deployments
-- ============================================================================
INSERT INTO app_deployments (
    id, service_name, version, region, zone, deployment_id,
    git_commit, git_branch, built_at, deployed_by, deployment_strategy,
    status, deployed_at
) VALUES
    (
        'd0000001-0000-4000-8000-000000000001',
        'entity-management', '1.0.0', 'eu-west-1', 'eu',
        'deploy-gha-184729',
        'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0',
        'main',
        NOW() - INTERVAL '30 minutes',
        'GitHub Actions (push to main)',
        'rolling',
        'active',
        NOW() - INTERVAL '30 minutes'
    ),
    (
        'd0000002-0000-4000-8000-000000000002',
        'entity-management', '1.0.1', 'eu-west-1', 'eu',
        'deploy-gha-184730',
        'b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1',
        'main',
        NOW() - INTERVAL '15 minutes',
        'GitHub Actions (push to main)',
        'rolling',
        'active',
        NOW() - INTERVAL '15 minutes'
    ),
    (
        'd0000003-0000-4000-8000-000000000003',
        'entity-management', '1.0.0', 'us-east-1', 'us',
        'deploy-gha-184731',
        'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0',
        'main',
        NOW() - INTERVAL '30 minutes',
        'GitHub Actions (push to main)',
        'rolling',
        'active',
        NOW() - INTERVAL '30 minutes'
    )
ON CONFLICT (service_name, version, region, deployment_id) DO NOTHING;

-- ============================================================================
-- 3. Seed: otel_metrics_config (custom/test overrides)
-- ============================================================================
-- The base metrics are already seeded in the up migration.
-- Here we add environment-specific overrides or additional test metrics.
INSERT INTO otel_metrics_config (
    metric_name, metric_type, metric_description, metric_unit,
    package_scope, operation_name, enabled, sampling_rate,
    aggregation_interval_seconds, attribute_dimensions
) VALUES
    (
        'app.startup.duration_ms',
        'histogram',
        'Application startup duration in milliseconds',
        'ms', 'pkg', 'NewApp',
        TRUE, 1.0, 300,
        '["service_name", "region", "migration_version"]'
    ),
    (
        'app.startup.attempts.total',
        'counter',
        'Total number of application startup attempts',
        '{attempt}', 'pkg', 'NewApp',
        TRUE, 1.0, 60,
        '["service_name", "region", "status"]'
    )
ON CONFLICT (metric_name) DO UPDATE SET
    enabled = TRUE,
    updated_at = NOW()
    WHERE otel_metrics_config.metric_name = 'app.startup.duration_ms'
       OR otel_metrics_config.metric_name = 'app.startup.attempts.total';

-- ============================================================================
-- 4. Verify seed data
-- ============================================================================
DO $$
DECLARE
    v_startup_count    INTEGER;
    v_deployment_count INTEGER;
    v_metric_count     INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_startup_count FROM app_startup_events;
    SELECT COUNT(*) INTO v_deployment_count FROM app_deployments;
    SELECT COUNT(*) INTO v_metric_count FROM otel_metrics_config;

    RAISE NOTICE 'ENTITYMGMT-12 seed data applied successfully.';
    RAISE NOTICE '  - app_startup_events: % records seeded', v_startup_count;
    RAISE NOTICE '  - app_deployments: % records seeded', v_deployment_count;
    RAISE NOTICE '  - otel_metrics_config: % metrics configured', v_metric_count;
    RAISE NOTICE '';
    RAISE NOTICE 'Seed data scenarios:';
    RAISE NOTICE '  1. Successful startup (v1.0.0): a0000001-... (running, 3200ms)';
    RAISE NOTICE '  2. Failed startup (DB conn):     a0000002-... (failed, connection refused)';
    RAISE NOTICE '  3. Successful startup (v1.0.1):  a0000003-... (running, 2500ms)';
    RAISE NOTICE '';
    RAISE NOTICE 'To verify: SELECT * FROM get_latest_successful_startup();';
    RAISE NOTICE '           SELECT * FROM get_last_startup_failure();';
    RAISE NOTICE '           SELECT * FROM get_startup_metrics();';
END;
$$;

COMMIT;
