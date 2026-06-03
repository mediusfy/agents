

# FINOPS-04: Cost vs. Reliability Trade-off Visualization Dashboard
## Schema Summary

### Domain Model

The trade-off dashboard answers the question: **"What happens to my costs if I raise/lower my reliability SLOs?"**

#### Core Tables (Schema: `finops`)

| Table | Purpose |
|-------|---------|
| `providers` | Cloud provider registry (AWS, Azure, GCP) |
| `regions` | Geographic regions for multi-cloud filtering |
| `services` | Service catalog with metadata |
| `service_slo_configs` | SLO targets and parameters per service |
| `monthly_cost_summary` | Aggregated monthly cost data (per service/provider/region) |
| `slo_attainment` | Monthly SLO performance snapshots |
| `incidents` | Incident records for bubble sizing |
| `trade_off_snapshots` | Materialized/cached scatter-plot dataset |
| `reliability_target_adjustments` | Audit log of user slider interactions |
| `outbox` | Transactional outbox for event publishing |

#### Key Design Decisions

1. **Multi-Cloud Partitioning**: Cost data is partitioned by `provider_id` and `region_id`. The dashboard filters by region (e.g., EU) to show only relevant costs.

2. **Eventual Consistency**: `trade_off_snapshots` acts as a refreshable cache. Cross-region data allows up to 5-minute staleness. A background worker refreshes snapshots and publishes `TradeOffDashboardRefreshed`.

3. **Cost Projection Model**: The `reliability_target_adjustments` table logs user slider movements. A cost-projection function estimates cost impact by analyzing historical cost vs. SLO correlation (e.g., higher SLO = more redundancy = higher cost).

4. **Outbox Pattern**: All domain events (`TradeOffDashboardRefreshed`, `CostVsSLOMapGenerated`, `ReliabilityTargetAdjusted`) are published via the transactional outbox to ensure at-least-once delivery.

5. **Scatter Plot Data**: `trade_off_snapshots` contains pre-joined data for fast rendering:
   - `service_name` - label
   - `monthly_cost` - x-axis
   - `slo_attainment_pct` - y-axis
   - `provider_name` - color
   - `incident_count` - bubble size
   - `region_filter` - for multi-cloud scoping

#### Migration Order

1. `FINOPS-04_000_trade_off_dashboard.up.sql` - Core schema tables
2. `FINOPS-04_001_outbox_triggers.up.sql` - Outbox triggers for events
3. Seed data for demo/development
4. Redis config for caching dashboard snapshots
