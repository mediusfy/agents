# FINOPS-01: Real-Time Cloud Cost Anomaly Detection - Schema Summary

## Overview

Schema for detecting cloud cost anomalies in real-time across AWS/GCP/Azure providers
and EU/US regions, with automatic deduplication and data sovereignty enforcement.

## Tables

| Table | Schema | Purpose |
|-------|--------|---------|
| `cost_telemetry` | `finops` | Raw cost metrics ingested per provider/region/service |
| `cost_baselines` | `finops` | Trailing 7-day rolling stats (mean, stddev) for dynamic thresholds |
| `cost_anomaly_events` | `finops` | Detected anomalies with full impact analysis |
| `anomaly_suppression_log` | `finops` | Audit log for suppressed duplicate anomalies |
| `event_outbox` | `finops` | Transactional outbox for domain events |

## Enums

- **`finops.provider_enum`**: `AWS`, `GCP`, `Azure`
- **`finops.region_enum`**: `EU`, `US`
- **`finops.residency_zone_enum`**: `EU`, `US`
- **`finops.anomaly_status_enum`**: `new`, `acknowledged`, `resolved`, `suppressed`

## Domain Events (Transactional Outbox)

| Event | Trigger | Payload Contains |
|-------|---------|-----------------|
| `finops.CostTelemetryIngested` | INSERT on `cost_telemetry` | provider, region, service, amount, ingested_at, metadata |
| `finops.CostAnomalyDetected` | INSERT on `cost_anomaly_events` (non-suppressed) | Full anomaly with deltas, impact, baseline refs |
| `finops.AnomalySuppressed` | INSERT on `anomaly_suppression_log` | original_anomaly_id, fingerprint, window, reason |

## Key Functions

### `finops.ingest_and_detect(p_provider, p_region, p_service, p_metric_name, p_amount, p_currency, p_metadata)`
**All-in-one ingestion pipeline**: Inserts telemetry → refreshes baseline → detects anomaly → returns results atomically.

Returns: `(telemetry_id, anomaly_id, is_anomaly, is_suppressed, percentage_delta)`

### `finops.compute_cost_baseline(p_provider, p_region, p_service, p_metric_name, p_threshold DEFAULT 3.00)`
Computes or refreshes the 7-day trailing statistical baseline via upsert.
Requires ≥2 samples in the window. Returns the baseline UUID or NULL.

### `finops.detect_cost_anomaly(p_telemetry_id, p_provider, p_region, p_service, p_metric_name, p_observed_cost, p_threshold DEFAULT 3.00)`
Compares observed cost against the dynamic threshold (`mean + 3 * stddev`).
Checks for duplicates within a 1-hour window (fingerprint = MD5 of provider|region|service|metric).
Returns anomaly UUID, or NULL if no anomaly detected.

## Dynamic Threshold Calculation

```
effective_threshold = mean_cost + (threshold_multiplier * stddev_cost)

Where:
  - mean_cost   = AVG(amount) over trailing 7 days
  - stddev_cost = STDDEV_POP(amount) over trailing 7 days
  - threshold_multiplier = 3.00 (configurable, stored per baseline)

Anomaly raised when: observed_cost > effective_threshold
```

## Computed Columns (auto-generated, no code needed)

| Table | Column | Formula |
|-------|--------|---------|
| `cost_telemetry` | `data_residency_zone` | `'EU' if region = 'EU' else 'US'` |
| `cost_anomaly_events` | `absolute_cost_delta` | `observed_cost - expected_cost` |
| `cost_anomaly_events` | `percentage_delta` | `((observed_cost - expected_cost) / expected_cost) * 100` |
| `cost_anomaly_events` | `data_residency_zone` | `'EU' if region = 'EU' else 'US'` |
| `cost_baselines` | `effective_threshold` | `mean_cost + (threshold_multiplier * stddev_cost)` |

## Projected Monthly Impact

```
projected_monthly_impact = absolute_cost_delta * 730
(730 = average hours per month)
```

## Deduplication Logic

1. A fingerprint is computed as `MD5(provider|region|service|metric_name)`
2. Before inserting a new anomaly, check for any non-suppressed anomaly with the same fingerprint within the last hour
3. If found, the new anomaly is marked `suppressed = TRUE` and logged in `anomaly_suppression_log`
4. The `finops.AnomalySuppressed` event is published via the outbox

## Data Residency & Row-Level Security

- `data_residency_zone` is a **generated column** derived from `region`
- RLS is enabled on `cost_telemetry`, `cost_anomaly_events`, and `anomaly_suppression_log`
- A restrictive policy ensures EU data is only visible to connections with appropriate role

**Production setup requires:**
```sql
CREATE ROLE finops_eu_reader;
CREATE ROLE finops_us_reader;
CREATE ROLE finops_admin;

GRANT USAGE ON SCHEMA finops TO finops_eu_reader, finops_us_reader;
GRANT SELECT ON finops.cost_telemetry TO finops_eu_reader, finops_us_reader;
-- ... etc.
```

## Index Strategy

| Index | Table | Purpose |
|-------|-------|---------|
| `idx_ct_lookup` | `cost_telemetry` | Fast lookup by (provider, region, service, metric, time) |
| `idx_ct_ingested_at` | `cost_telemetry` | Time-range scans for baseline computation |
| `idx_ct_residency_zone` | `cost_telemetry` | Residency-based filtering |
| `idx_ct_metadata_gin` | `cost_telemetry` | JSONB metadata queries |
| `idx_cb_lookup` | `cost_baselines` | Unique constraint lookup + fast retrieval |
| `idx_cae_status` | `cost_anomaly_events` | Filter active anomalies (partial index) |
| `idx_cae_lookup` | `cost_anomaly_events` | Provider/region/service/metric time-series |
| `idx_asl_fingerprint` | `anomaly_suppression_log` | Dedup fingerprint lookup |
| `idx_eo_unpublished` | `event_outbox` | Poll for unpublished events (partial index) |

## Redis Integration (see separate config)

Redis is used for:
1. **Dedup cache**: TTL-based dedup keys for the 1-hour suppression window (faster than DB lookups)
2. **Dashboard fan-out**: Pub/Sub channels for real-time SRE dashboard updates
3. **Rate limiting**: Throttle telemetry ingestion per provider/region
