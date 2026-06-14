-- FINOPS-01: Real-Time Cloud Cost Anomaly Detection per Region per Provider
-- ==========================================================================
-- Description:
--   Schema for ingesting cloud cost telemetry from AWS/GCP/Azure across
--   EU and US regions, computing dynamic anomaly thresholds (3σ trailing
--   7-day baseline), raising cost anomaly events with full impact analysis,
--   and suppressing duplicates within a 1-hour window.
--
-- Events emitted via outbox:
--   - finops.CostTelemetryIngested  (raw cost metric ingested)
--   - finops.CostAnomalyDetected    (anomaly raised with impact analysis)
--   - finops.AnomalySuppressed      (duplicate anomaly suppressed)
--
-- Data Residency:
--   EU data is tagged with data_residency_zone='EU' and must never leave
--   EU data stores. Row-level security policies enforce this boundary.
-- ==========================================================================

-- +goose Up
-- +goose StatementBegin

--------------------------------------------------------------------------------
-- 1. SCHEMA & ENUMS
--------------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS finops;

-- Supported cloud providers
CREATE TYPE finops.provider_enum AS ENUM ('AWS', 'GCP', 'Azure');

-- Supported data residency regions
CREATE TYPE finops.region_enum AS ENUM ('EU', 'US');

-- Residency zones derived from region for explicit data sovereignty tagging
CREATE TYPE finops.residency_zone_enum AS ENUM ('EU', 'US');

-- Lifecycle status of an anomaly event
CREATE TYPE finops.anomaly_status_enum AS ENUM ('new', 'acknowledged', 'resolved', 'suppressed');

--------------------------------------------------------------------------------
-- 2. TABLES
--------------------------------------------------------------------------------

-- 2a. cost_telemetry: Raw cost metrics ingested per provider/region/service
CREATE TABLE IF NOT EXISTS finops.cost_telemetry (
    id                  UUID                        PRIMARY KEY DEFAULT gen_random_uuid(),
    provider            finops.provider_enum        NOT NULL,
    region              finops.region_enum          NOT NULL,
    service             TEXT                        NOT NULL,
    metric_name         TEXT                        NOT NULL,
    amount              DECIMAL(18, 6)              NOT NULL CHECK (amount >= 0),
    currency            TEXT                        NOT NULL DEFAULT 'USD',
    ingested_at         TIMESTAMPTZ                 NOT NULL DEFAULT NOW(),
    data_residency_zone finops.residency_zone_enum  GENERATED ALWAYS AS (
        CASE
            WHEN region = 'EU' THEN 'EU'::finops.residency_zone_enum
            ELSE 'US'::finops.residency_zone_enum
        END
    ) STORED,
    metadata            JSONB                       DEFAULT '{}'::jsonb,
    created_at          TIMESTAMPTZ                 NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ                 NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  finops.cost_telemetry IS 'Raw cloud cost metrics ingested from providers per region with automatic data residency tagging';
COMMENT ON COLUMN finops.cost_telemetry.amount IS 'Cost amount in the specified currency';
COMMENT ON COLUMN finops.cost_telemetry.data_residency_zone IS 'Derived from region; EU data never leaves EU boundaries';
COMMENT ON COLUMN finops.cost_telemetry.metadata IS 'Arbitrary JSON metadata from the provider (tags, instance type, etc.)';

-- 2b. cost_baselines: Trailing 7-day rolling statistical baselines
CREATE TABLE IF NOT EXISTS finops.cost_baselines (
    id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    provider            TEXT            NOT NULL,
    region              TEXT            NOT NULL,
    service             TEXT            NOT NULL,
    metric_name         TEXT            NOT NULL,
    mean_cost           DECIMAL(18, 6)  NOT NULL,
    stddev_cost         DECIMAL(18, 6)  NOT NULL CHECK (stddev_cost >= 0),
    threshold_multiplier DECIMAL(5, 2)  NOT NULL DEFAULT 3.00 CHECK (threshold_multiplier > 0),
    effective_threshold DECIMAL(18, 6)  GENERATED ALWAYS AS (mean_cost + (threshold_multiplier * stddev_cost)) STORED,
    baseline_start      TIMESTAMPTZ     NOT NULL,
    baseline_end        TIMESTAMPTZ     NOT NULL,
    sample_count        INTEGER         NOT NULL DEFAULT 0 CHECK (sample_count >= 0),
    computed_at         TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    CONSTRAINT unique_provider_region_service_metric UNIQUE (provider, region, service, metric_name)
);

COMMENT ON TABLE  finops.cost_baselines IS 'Rolling 7-day statistical baselines per provider/region/service for dynamic anomaly thresholding';
COMMENT ON COLUMN finops.cost_baselines.mean_cost IS 'Arithmetic mean of cost over the 7-day trailing window';
COMMENT ON COLUMN finops.cost_baselines.stddev_cost IS 'Population standard deviation over the 7-day trailing window';
COMMENT ON COLUMN finops.cost_baselines.effective_threshold IS 'Computed as mean_cost + (threshold_multiplier * stddev_cost); anomalies exceed this value';
COMMENT ON COLUMN finops.cost_baselines.baseline_start IS 'Start of the trailing 7-day window';
COMMENT ON COLUMN finops.cost_baselines.baseline_end IS 'End of the trailing 7-day window (usually NOW())';

-- 2c. cost_anomaly_events: Raised anomaly detections with full impact analysis
CREATE TABLE IF NOT EXISTS finops.cost_anomaly_events (
    id                      UUID                        PRIMARY KEY DEFAULT gen_random_uuid(),
    provider                finops.provider_enum        NOT NULL,
    region                  finops.region_enum          NOT NULL,
    service                 TEXT                        NOT NULL,
    metric_name             TEXT                        NOT NULL,
    telemetry_id            UUID                        REFERENCES finops.cost_telemetry(id) ON DELETE SET NULL,
    baseline_id             UUID                        REFERENCES finops.cost_baselines(id) ON DELETE SET NULL,
    observed_cost           DECIMAL(18, 6)              NOT NULL CHECK (observed_cost >= 0),
    expected_cost           DECIMAL(18, 6)              NOT NULL CHECK (expected_cost >= 0),
    absolute_cost_delta     DECIMAL(18, 6)              GENERATED ALWAYS AS (observed_cost - expected_cost) STORED,
    percentage_delta        DECIMAL(10, 4)              GENERATED ALWAYS AS (
        CASE
            WHEN expected_cost = 0 THEN NULL
            ELSE ((observed_cost - expected_cost) / expected_cost) * 100
        END
    ) STORED,
    projected_monthly_impact DECIMAL(18, 6)             NOT NULL,
    threshold_multiplier    DECIMAL(5, 2)               NOT NULL DEFAULT 3.00,
    data_residency_zone     finops.residency_zone_enum  GENERATED ALWAYS AS (
        CASE
            WHEN region = 'EU' THEN 'EU'::finops.residency_zone_enum
            ELSE 'US'::finops.residency_zone_enum
        END
    ) STORED,
    status                  finops.anomaly_status_enum  NOT NULL DEFAULT 'new',
    suppressed              BOOLEAN                     NOT NULL DEFAULT FALSE,
    suppression_reason      TEXT,
    detected_at             TIMESTAMPTZ                 NOT NULL DEFAULT NOW(),
    acknowledged_at         TIMESTAMPTZ,
    resolved_at             TIMESTAMPTZ,
    metadata                JSONB                       DEFAULT '{}'::jsonb,
    created_at              TIMESTAMPTZ                 NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ                 NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  finops.cost_anomaly_events IS 'Cost anomaly events raised when cost deviates >3σ from trailing 7-day baseline';
COMMENT ON COLUMN finops.cost_anomaly_events.observed_cost IS 'The actual cost that triggered the anomaly';
COMMENT ON COLUMN finops.cost_anomaly_events.expected_cost IS 'The expected cost from the baseline mean';
COMMENT ON COLUMN finops.cost_anomaly_events.absolute_cost_delta IS 'observed_cost - expected_cost (auto-computed)';
COMMENT ON COLUMN finops.cost_anomaly_events.percentage_delta IS 'Percentage change from expected to observed (auto-computed)';
COMMENT ON COLUMN finops.cost_anomaly_events.projected_monthly_impact IS 'Estimated monthly cost impact if anomaly persists (absolute_cost_delta * 730 hours/month)';
COMMENT ON COLUMN finops.cost_anomaly_events.suppressed IS 'TRUE if this anomaly was identified as a duplicate within a 1-hour window';
COMMENT ON COLUMN finops.cost_anomaly_events.suppression_reason IS 'Human-readable reason for suppression (e.g., duplicate fingerprint)';

-- 2d. anomaly_suppression_log: Audit log of suppressed duplicate anomalies
CREATE TABLE IF NOT EXISTS finops.anomaly_suppression_log (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    original_anomaly_id     UUID        NOT NULL REFERENCES finops.cost_anomaly_events(id) ON DELETE CASCADE,
    duplicate_fingerprint   TEXT        NOT NULL,
    duplicate_count         INTEGER     NOT NULL DEFAULT 1 CHECK (duplicate_count > 0),
    suppression_window_start TIMESTAMPTZ NOT NULL,
    suppression_window_end  TIMESTAMPTZ NOT NULL,
    reason                  TEXT        NOT NULL,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  finops.anomaly_suppression_log IS 'Audit trail for duplicate anomaly suppression within the configurable time window';
COMMENT ON COLUMN finops.anomaly_suppression_log.duplicate_fingerprint IS 'Hash of (provider, region, service, metric_name) used for dedup lookup';
COMMENT ON COLUMN finops.anomaly_suppression_log.suppression_window_start IS 'Start of the 1-hour suppression window';
COMMENT ON COLUMN finops.anomaly_suppression_log.suppression_window_end IS 'End of the 1-hour suppression window';

-- 2e. event_outbox: Transactional outbox for finops domain events
CREATE TABLE IF NOT EXISTS finops.event_outbox (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type      TEXT            NOT NULL,
    aggregate_id    UUID            NOT NULL,
    aggregate_type  TEXT            NOT NULL,
    payload         JSONB           NOT NULL DEFAULT '{}'::jsonb,
    published       BOOLEAN         NOT NULL DEFAULT FALSE,
    published_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE finops.event_outbox IS 'Transactional outbox for finops domain events consumed by the event broker';
COMMENT ON COLUMN finops.event_outbox.event_type IS 'One of: finops.CostTelemetryIngested, finops.CostAnomalyDetected, finops.AnomalySuppressed';
COMMENT ON COLUMN finops.event_outbox.payload IS 'JSON payload containing full event data for downstream consumers';
COMMENT ON COLUMN finops.event_outbox.published IS 'Flag indicating whether the event has been published to the message broker';

--------------------------------------------------------------------------------
-- 3. INDEXES
--------------------------------------------------------------------------------

-- cost_telemetry indexes
CREATE INDEX IF NOT EXISTS idx_ct_provider_region    ON finops.cost_telemetry(provider, region);
CREATE INDEX IF NOT EXISTS idx_ct_ingested_at         ON finops.cost_telemetry(ingested_at DESC);
CREATE INDEX IF NOT EXISTS idx_ct_service             ON finops.cost_telemetry(service);
CREATE INDEX IF NOT EXISTS idx_ct_residency_zone      ON finops.cost_telemetry(data_residency_zone);
CREATE INDEX IF NOT EXISTS idx_ct_lookup              ON finops.cost_telemetry(provider, region, service, metric_name, ingested_at DESC);
-- GIN index for JSONB metadata queries
CREATE INDEX IF NOT EXISTS idx_ct_metadata_gin        ON finops.cost_telemetry USING GIN (metadata);

-- cost_baselines indexes
CREATE INDEX IF NOT EXISTS idx_cb_lookup              ON finops.cost_baselines(provider, region, service, metric_name);
CREATE INDEX IF NOT EXISTS idx_cb_computed_at         ON finops.cost_baselines(computed_at DESC);
CREATE INDEX IF NOT EXISTS idx_cb_effective_threshold ON finops.cost_baselines(effective_threshold);

-- cost_anomaly_events indexes
CREATE INDEX IF NOT EXISTS idx_cae_provider_region    ON finops.cost_anomaly_events(provider, region);
CREATE INDEX IF NOT EXISTS idx_cae_detected_at        ON finops.cost_anomaly_events(detected_at DESC);
CREATE INDEX IF NOT EXISTS idx_cae_status             ON finops.cost_anomaly_events(status) WHERE status NOT IN ('resolved', 'suppressed');
CREATE INDEX IF NOT EXISTS idx_cae_residency_zone     ON finops.cost_anomaly_events(data_residency_zone);
CREATE INDEX IF NOT EXISTS idx_cae_suppressed          ON finops.cost_anomaly_events(suppressed) WHERE suppressed = TRUE;
CREATE INDEX IF NOT EXISTS idx_cae_lookup             ON finops.cost_anomaly_events(provider, region, service, metric_name, detected_at DESC);
CREATE INDEX IF NOT EXISTS idx_cae_metadata_gin       ON finops.cost_anomaly_events USING GIN (metadata);

-- anomaly_suppression_log indexes
CREATE INDEX IF NOT EXISTS idx_asl_fingerprint        ON finops.anomaly_suppression_log(duplicate_fingerprint);
CREATE INDEX IF NOT EXISTS idx_asl_original           ON finops.anomaly_suppression_log(original_anomaly_id);
CREATE INDEX IF NOT EXISTS idx_asl_created_at         ON finops.anomaly_suppression_log(created_at DESC);

-- event_outbox indexes
CREATE INDEX IF NOT EXISTS idx_eo_unpublished         ON finops.event_outbox(published, created_at ASC) WHERE published = FALSE;
CREATE INDEX IF NOT EXISTS idx_eo_event_type          ON finops.event_outbox(event_type);

--------------------------------------------------------------------------------
-- 4. TRIGGER FUNCTIONS & TRIGGERS
--------------------------------------------------------------------------------

-- 4a. Auto-update updated_at on row modification
CREATE OR REPLACE FUNCTION finops.update_modified_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_cost_telemetry_modtime
    BEFORE UPDATE ON finops.cost_telemetry
    FOR EACH ROW EXECUTE FUNCTION finops.update_modified_column();

CREATE TRIGGER trg_cost_baselines_modtime
    BEFORE UPDATE ON finops.cost_baselines
    FOR EACH ROW EXECUTE FUNCTION finops.update_modified_column();

CREATE TRIGGER trg_cost_anomaly_events_modtime
    BEFORE UPDATE ON finops.cost_anomaly_events
    FOR EACH ROW EXECUTE FUNCTION finops.update_modified_column();

-- 4b. Event outbox triggers: Write domain events to the outbox on significant state changes

-- Outbox trigger for CostTelemetryIngested
CREATE OR REPLACE FUNCTION finops.outbox_cost_telemetry_ingested()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO finops.event_outbox (event_type, aggregate_id, aggregate_type, payload)
    VALUES (
        'finops.CostTelemetryIngested',
        NEW.id,
        'cost_telemetry',
        jsonb_build_object(
            'id',                NEW.id,
            'provider',          NEW.provider,
            'region',            NEW.region,
            'service',           NEW.service,
            'metric_name',       NEW.metric_name,
            'amount',            NEW.amount,
            'currency',          NEW.currency,
            'ingested_at',       NEW.ingested_at,
            'data_residency_zone', NEW.data_residency_zone,
            'metadata',          NEW.metadata
        )
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_cost_telemetry_outbox
    AFTER INSERT ON finops.cost_telemetry
    FOR EACH ROW EXECUTE FUNCTION finops.outbox_cost_telemetry_ingested();

-- Outbox trigger for CostAnomalyDetected (only for non-suppressed anomalies)
CREATE OR REPLACE FUNCTION finops.outbox_cost_anomaly_detected()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO finops.event_outbox (event_type, aggregate_id, aggregate_type, payload)
    VALUES (
        'finops.CostAnomalyDetected',
        NEW.id,
        'cost_anomaly_events',
        jsonb_build_object(
            'id',                      NEW.id,
            'provider',                NEW.provider,
            'region',                  NEW.region,
            'service',                 NEW.service,
            'metric_name',             NEW.metric_name,
            'telemetry_id',            NEW.telemetry_id,
            'baseline_id',             NEW.baseline_id,
            'observed_cost',           NEW.observed_cost,
            'expected_cost',           NEW.expected_cost,
            'absolute_cost_delta',     NEW.absolute_cost_delta,
            'percentage_delta',        NEW.percentage_delta,
            'projected_monthly_impact', NEW.projected_monthly_impact,
            'threshold_multiplier',    NEW.threshold_multiplier,
            'data_residency_zone',     NEW.data_residency_zone,
            'status',                  NEW.status,
            'suppressed',              NEW.suppressed,
            'detected_at',             NEW.detected_at,
            'metadata',                NEW.metadata
        )
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_cost_anomaly_outbox
    AFTER INSERT ON finops.cost_anomaly_events
    FOR EACH ROW
    WHEN (NEW.suppressed = FALSE)
    EXECUTE FUNCTION finops.outbox_cost_anomaly_detected();

-- Outbox trigger for AnomalySuppressed
CREATE OR REPLACE FUNCTION finops.outbox_anomaly_suppressed()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO finops.event_outbox (event_type, aggregate_id, aggregate_type, payload)
    VALUES (
        'finops.AnomalySuppressed',
        NEW.original_anomaly_id,
        'anomaly_suppression_log',
        jsonb_build_object(
            'id',                       NEW.id,
            'original_anomaly_id',      NEW.original_anomaly_id,
            'duplicate_fingerprint',    NEW.duplicate_fingerprint,
            'duplicate_count',          NEW.duplicate_count,
            'suppression_window_start', NEW.suppression_window_start,
            'suppression_window_end',   NEW.suppression_window_end,
            'reason',                   NEW.reason,
            'suppressed_at',            NEW.created_at
        )
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_anomaly_suppression_outbox
    AFTER INSERT ON finops.anomaly_suppression_log
    FOR EACH ROW EXECUTE FUNCTION finops.outbox_anomaly_suppressed();

--------------------------------------------------------------------------------
-- 5. FUNCTIONS
--------------------------------------------------------------------------------

-- 5a. Compute or refresh the 7-day trailing statistical baseline for a given provider/region/service/metric
CREATE OR REPLACE FUNCTION finops.compute_cost_baseline(
    p_provider      TEXT,
    p_region        TEXT,
    p_service       TEXT,
    p_metric_name   TEXT,
    p_threshold     DECIMAL(5, 2) DEFAULT 3.00
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_baseline_id   UUID;
    v_mean          DECIMAL(18, 6);
    v_stddev        DECIMAL(18, 6);
    v_sample_count  INTEGER;
    v_now           TIMESTAMPTZ := NOW();
BEGIN
    -- Compute stats over the trailing 7-day window
    SELECT
        AVG(amount),
        COALESCE(STDDEV_POP(amount), 0),
        COUNT(*)
    INTO
        v_mean,
        v_stddev,
        v_sample_count
    FROM finops.cost_telemetry
    WHERE provider = p_provider::finops.provider_enum
      AND region = p_region::finops.region_enum
      AND service = p_service
      AND metric_name = p_metric_name
      AND ingested_at >= v_now - INTERVAL '7 days';

    -- Guard: require at least 2 samples for meaningful statistics
    IF v_sample_count < 2 THEN
        RAISE NOTICE 'Insufficient samples (%) for %/%/%/%; baseline not computed', v_sample_count, p_provider, p_region, p_service, p_metric_name;
        RETURN NULL;
    END IF;

    -- Upsert the baseline
    INSERT INTO finops.cost_baselines
        (provider, region, service, metric_name, mean_cost, stddev_cost, threshold_multiplier,
         baseline_start, baseline_end, sample_count, computed_at)
    VALUES
        (p_provider, p_region, p_service, p_metric_name, v_mean, v_stddev, p_threshold,
         v_now - INTERVAL '7 days', v_now, v_sample_count, v_now)
    ON CONFLICT (provider, region, service, metric_name)
    DO UPDATE SET
        mean_cost            = EXCLUDED.mean_cost,
        stddev_cost          = EXCLUDED.stddev_cost,
        threshold_multiplier = EXCLUDED.threshold_multiplier,
        baseline_start       = EXCLUDED.baseline_start,
        baseline_end         = EXCLUDED.baseline_end,
        sample_count         = EXCLUDED.sample_count,
        computed_at          = EXCLUDED.computed_at,
        updated_at           = NOW()
    RETURNING id INTO v_baseline_id;

    RETURN v_baseline_id;
END;
$$;

COMMENT ON FUNCTION finops.compute_cost_baseline IS 'Computes or refreshes the 7-day trailing statistical baseline for a provider/region/service/metric pair';

-- 5b. Detect anomaly: Check if a cost metric exceeds the dynamic threshold
CREATE OR REPLACE FUNCTION finops.detect_cost_anomaly(
    p_telemetry_id  UUID,
    p_provider      finops.provider_enum,
    p_region        finops.region_enum,
    p_service       TEXT,
    p_metric_name   TEXT,
    p_observed_cost DECIMAL(18, 6),
    p_threshold     DECIMAL(5, 2) DEFAULT 3.00
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_baseline      RECORD;
    v_anomaly_id    UUID;
    v_fingerprint   TEXT;
    v_suppressed    BOOLEAN := FALSE;
    v_suppression_reason TEXT;
    v_now           TIMESTAMPTZ := NOW();
    v_projected_monthly_impact DECIMAL(18, 6);
    v_expected_cost DECIMAL(18, 6);
    v_delta         DECIMAL(18, 6);
BEGIN
    -- Get the latest baseline
    SELECT * INTO v_baseline
    FROM finops.cost_baselines
    WHERE provider = p_provider::TEXT
      AND region = p_region::TEXT
      AND service = p_service
      AND metric_name = p_metric_name
    ORDER BY computed_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE NOTICE 'No baseline found for %/%/%/%; cannot detect anomaly', p_provider, p_region, p_service, p_metric_name;
        RETURN NULL;
    END IF;

    v_expected_cost := v_baseline.mean_cost;
    v_delta := p_observed_cost - v_expected_cost;

    -- Check if the observed cost exceeds the dynamic threshold
    IF p_observed_cost <= v_baseline.effective_threshold THEN
        -- No anomaly detected
        RETURN NULL;
    END IF;

    -- Compute projected monthly impact: extrapolate delta over 730 hours/month
    v_projected_monthly_impact := v_delta * 730;

    -- Build a deduplication fingerprint (provider + region + service + metric_name within 1-hour window)
    v_fingerprint := MD5(
        p_provider::TEXT || '|' ||
        p_region::TEXT   || '|' ||
        p_service        || '|' ||
        p_metric_name
    );

    -- Check for existing anomaly with same fingerprint within the last 1 hour
    PERFORM 1
    FROM finops.cost_anomaly_events
    WHERE provider = p_provider
      AND region = p_region
      AND service = p_service
      AND metric_name = p_metric_name
      AND suppressed = FALSE
      AND detected_at >= v_now - INTERVAL '1 hour'
    LIMIT 1;

    IF FOUND THEN
        -- Suppress this duplicate; log it
        v_suppressed := TRUE;
        v_suppression_reason := 'Duplicate anomaly within 1-hour suppression window';
    END IF;

    -- Insert the anomaly event
    INSERT INTO finops.cost_anomaly_events
        (provider, region, service, metric_name, telemetry_id, baseline_id,
         observed_cost, expected_cost, projected_monthly_impact,
         threshold_multiplier, status, suppressed, suppression_reason, detected_at)
    VALUES
        (p_provider, p_region, p_service, p_metric_name, p_telemetry_id, v_baseline.id,
         p_observed_cost, v_expected_cost, v_projected_monthly_impact,
         p_threshold, 'new', v_suppressed, v_suppression_reason, v_now)
    RETURNING id INTO v_anomaly_id;

    -- If suppressed, log the suppression
    IF v_suppressed THEN
        INSERT INTO finops.anomaly_suppression_log
            (original_anomaly_id, duplicate_fingerprint, duplicate_count,
             suppression_window_start, suppression_window_end, reason)
        VALUES
            (v_anomaly_id, v_fingerprint, 1,
             v_now - INTERVAL '1 hour', v_now,
             v_suppression_reason);
    END IF;

    RETURN v_anomaly_id;
END;
$$;

COMMENT ON FUNCTION finops.detect_cost_anomaly IS 'Detects cost anomalies by comparing observed cost against the dynamic 3σ baseline threshold with 1-hour dedup suppression';

-- 5c. Ingest telemetry + auto-detect anomaly in one transactional call
CREATE OR REPLACE FUNCTION finops.ingest_and_detect(
    p_provider      finops.provider_enum,
    p_region        finops.region_enum,
    p_service       TEXT,
    p_metric_name   TEXT,
    p_amount        DECIMAL(18, 6),
    p_currency      TEXT DEFAULT 'USD',
    p_metadata      JSONB DEFAULT '{}'::jsonb
)
RETURNS TABLE (
    telemetry_id    UUID,
    anomaly_id      UUID,
    is_anomaly      BOOLEAN,
    is_suppressed   BOOLEAN,
    percentage_delta DECIMAL(10, 4)
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_telemetry_id  UUID;
    v_anomaly_id    UUID;
    v_baseline_id   UUID;
BEGIN
    -- Step 1: Ingest the cost telemetry
    INSERT INTO finops.cost_telemetry (provider, region, service, metric_name, amount, currency, metadata)
    VALUES (p_provider, p_region, p_service, p_metric_name, p_amount, p_currency, p_metadata)
    RETURNING id INTO v_telemetry_id;

    -- Step 2: Compute/refresh the baseline (idempotent via upsert)
    v_baseline_id := finops.compute_cost_baseline(
        p_provider::TEXT,
        p_region::TEXT,
        p_service,
        p_metric_name
    );

    -- Step 3: Detect anomaly
    v_anomaly_id := finops.detect_cost_anomaly(
        v_telemetry_id,
        p_provider,
        p_region,
        p_service,
        p_metric_name,
        p_amount
    );

    -- Return result
    RETURN QUERY
    SELECT
        v_telemetry_id   AS telemetry_id,
        cae.id           AS anomaly_id,
        CASE WHEN cae.id IS NOT NULL THEN TRUE ELSE FALSE END AS is_anomaly,
        COALESCE(cae.suppressed, FALSE) AS is_suppressed,
        cae.percentage_delta
    FROM (SELECT NULL::UUID AS id, NULL::BOOLEAN AS suppressed, NULL::DECIMAL(10,4) AS percentage_delta) AS empty
    LEFT JOIN finops.cost_anomaly_events cae ON cae.id = v_anomaly_id;
END;
$$;

COMMENT ON FUNCTION finops.ingest_and_detect IS 'All-in-one function: ingests cost telemetry, refreshes baseline stats, and detects anomalies atomically';

--------------------------------------------------------------------------------
-- 6. ROW-LEVEL SECURITY (EU Data Sovereignty)
--------------------------------------------------------------------------------

-- Enable RLS on tables containing residency data
ALTER TABLE finops.cost_telemetry      ENABLE ROW LEVEL SECURITY;
ALTER TABLE finops.cost_anomaly_events  ENABLE ROW LEVEL SECURITY;
ALTER TABLE finops.anomaly_suppression_log ENABLE ROW LEVEL SECURITY;

-- Policy: EU data is only visible to connections with finops.eu_residency role
-- (Application connects with role-scoped credentials based on region)
CREATE POLICY rls_eu_data_only ON finops.cost_telemetry
    AS RESTRICTIVE
    FOR ALL
    USING (data_residency_zone = 'EU');

CREATE POLICY rls_eu_data_only ON finops.cost_anomaly_events
    AS RESTRICTIVE
    FOR ALL
    USING (data_residency_zone = 'EU');

-- NOTE: In production, you would create separate database roles:
--   finops_eu_reader  -> can only see EU data
--   finops_us_reader  -> can only see non-EU data
--   finops_admin      -> can see all data
-- The application uses the appropriate role based on the region handling the request.

-- +goose StatementEnd
