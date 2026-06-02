

# RUFKIS-04: FinOps Monitoring with Cost Anomaly Alerts

## Overview
FinOps Monitoring bounded context for tracking Kubernetes cluster costs, detecting anomalous spending patterns, and triggering alerts. Supports multi-cloud cost aggregation, budget policies, and cost allocation tagging.

## Database Schema

### Tables

1. **cost_metrics** - Raw cost data points aggregated from cloud providers
2. **cost_anomaly_rules** - Configurable detection rules for cost anomalies
3. **cost_anomaly_alerts** - Generated alerts when anomalies are detected
4. **budget_policies** - Budget thresholds and enforcement rules
5. **cost_allocation_tags** - Kubernetes-native cost allocation metadata
6. **cost_metric_snapshots** - Periodic snapshots for trend analysis

### Redis Caching
- **cost:daily:{date}:{cluster_id}** - Cached daily cost aggregates
- **cost:anomaly:active** - Currently active anomaly alerts (sorted by severity)
- **cost:budget:{policy_id}:status** - Budget consumption status
- Rate limiting: 1000 req/min per user for cost API endpoints

## Domain Events
- CostMetricRecorded
- CostAnomalyDetected
- CostAnomalyResolved
- BudgetThresholdExceeded
- BudgetPolicyUpdated

## Key Indexes
- idx_cost_metrics_cluster_period on cost_metrics(cluster_id, period_start)
- idx_cost_anomaly_alerts_status on cost_anomaly_alerts(status, severity)
- idx_budget_policies_scope on budget_policies(scope_type, scope_value)
