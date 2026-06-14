-- FINOPS-01: Rollback - Real-Time Cloud Cost Anomaly Detection
-- ==========================================================================
-- +goose Down
-- +goose StatementBegin

-- Drop RLS policies
ALTER TABLE IF EXISTS finops.anomaly_suppression_log NO FORCE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS finops.cost_anomaly_events     NO FORCE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS finops.cost_telemetry          NO FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS rls_eu_data_only ON finops.anomaly_suppression_log;
DROP POLICY IF EXISTS rls_eu_data_only ON finops.cost_anomaly_events;
DROP POLICY IF EXISTS rls_eu_data_only ON finops.cost_telemetry;

ALTER TABLE IF EXISTS finops.anomaly_suppression_log DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS finops.cost_anomaly_events     DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS finops.cost_telemetry          DISABLE ROW LEVEL SECURITY;

-- Drop functions (in reverse dependency order)
DROP FUNCTION IF EXISTS finops.ingest_and_detect(finops.provider_enum, finops.region_enum, TEXT, TEXT, DECIMAL, TEXT, JSONB);
DROP FUNCTION IF EXISTS finops.detect_cost_anomaly(UUID, finops.provider_enum, finops.region_enum, TEXT, TEXT, DECIMAL, DECIMAL);
DROP FUNCTION IF EXISTS finops.compute_cost_baseline(TEXT, TEXT, TEXT, TEXT, DECIMAL);

-- Drop triggers
DROP TRIGGER IF EXISTS trg_anomaly_suppression_outbox ON finops.anomaly_suppression_log;
DROP TRIGGER IF EXISTS trg_cost_anomaly_outbox         ON finops.cost_anomaly_events;
DROP TRIGGER IF EXISTS trg_cost_telemetry_outbox       ON finops.cost_telemetry;
DROP TRIGGER IF EXISTS trg_cost_anomaly_events_modtime ON finops.cost_anomaly_events;
DROP TRIGGER IF EXISTS trg_cost_baselines_modtime      ON finops.cost_baselines;
DROP TRIGGER IF EXISTS trg_cost_telemetry_modtime      ON finops.cost_telemetry;

-- Drop trigger functions
DROP FUNCTION IF EXISTS finops.outbox_anomaly_suppressed;
DROP FUNCTION IF EXISTS finops.outbox_cost_anomaly_detected;
DROP FUNCTION IF EXISTS finops.outbox_cost_telemetry_ingested;
DROP FUNCTION IF EXISTS finops.update_modified_column;

-- Drop tables (in dependency order)
DROP TABLE IF EXISTS finops.event_outbox;
DROP TABLE IF EXISTS finops.anomaly_suppression_log;
DROP TABLE IF EXISTS finops.cost_anomaly_events;
DROP TABLE IF EXISTS finops.cost_baselines;
DROP TABLE IF EXISTS finops.cost_telemetry;

-- Drop enums
DROP TYPE IF EXISTS finops.anomaly_status_enum;
DROP TYPE IF EXISTS finops.residency_zone_enum;
DROP TYPE IF EXISTS finops.region_enum;
DROP TYPE IF EXISTS finops.provider_enum;

-- Drop schema (only if empty)
DROP SCHEMA IF EXISTS finops;

-- +goose StatementEnd
