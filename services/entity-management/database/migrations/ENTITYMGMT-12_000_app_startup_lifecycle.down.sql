-- Migration: ENTITYMGMT-12_000_app_startup_lifecycle.down.sql
-- Story: ENTITYMGMT-12 — Rollback application startup lifecycle tracking
-- Bounded Context: Entity Management
--
-- Reverses ENTITYMGMT-12_000_app_startup_lifecycle.up.sql
--
-- Ordered rollback:
--   1. Drop functions (depend on tables)
--   2. Drop triggers on app_startup_events and otel_metrics_config
--   3. Drop tables (app_startup_events, app_deployments, otel_metrics_config)
--   4. Drop indexes (dropped automatically with tables via CASCADE)
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. Drop functions (in reverse dependency order)
-- ============================================================================

-- Gherkin verification function
DROP FUNCTION IF EXISTS verify_app_startup_lifecycle();

-- Aggregate metrics function
DROP FUNCTION IF EXISTS get_startup_metrics(VARCHAR, INTEGER);

-- Shutdown tracking
DROP FUNCTION IF EXISTS record_app_shutdown(VARCHAR, VARCHAR);

-- Crash-loop detection
DROP FUNCTION IF EXISTS count_recent_startup_failures(VARCHAR, INTEGER);

-- Diagnostics
DROP FUNCTION IF EXISTS get_last_startup_failure(VARCHAR);
DROP FUNCTION IF EXISTS get_latest_successful_startup(VARCHAR);

-- Combined atomic operations
DROP FUNCTION IF EXISTS record_app_startup_failure(VARCHAR, TEXT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER, VARCHAR, INTEGER);
DROP FUNCTION IF EXISTS record_app_startup(VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER, VARCHAR, INTEGER, INTEGER, VARCHAR, VARCHAR);

-- Outbox event enqueue functions
DROP FUNCTION IF EXISTS enqueue_app_startup_failed_event(VARCHAR, TEXT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER);
DROP FUNCTION IF EXISTS enqueue_app_started_event(VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER, VARCHAR, INTEGER, INTEGER, VARCHAR);

-- ============================================================================
-- 2. Drop triggers
-- ============================================================================
DROP TRIGGER IF EXISTS update_otel_metrics_config_modtime ON otel_metrics_config;
DROP TRIGGER IF EXISTS update_app_startup_events_modtime ON app_startup_events;

-- ============================================================================
-- 3. Drop tables (with CASCADE to handle indexes and FK references)
-- ============================================================================
DROP TABLE IF EXISTS app_startup_events CASCADE;
DROP TABLE IF EXISTS app_deployments CASCADE;
DROP TABLE IF EXISTS otel_metrics_config CASCADE;

-- ============================================================================
-- 4. NOT dropping:
--    - outbox_events entries with event_type = 'entitymanagement.app.started'
--      or 'entitymanagement.app.startup_failed' — they are data, not schema.
--      They will remain in the outbox and be published by the relay.
--    - update_modified_column() function — shared with other migrations.
--
-- ============================================================================

COMMIT;
