# Automated FinOps ROI Theme

> **Stories**: FINOPS-01 · FINOPS-02 · FINOPS-03 · FINOPS-04  
> **Priority**: P0 (2 stories) + P1 (2 stories)  
> **Phase**: Phase 1 (P0) + Phase 2 (P1)

---

## Theme Overview

The Automated FinOps ROI theme provides **real-time cost observability and optimization** across AWS, GCP, and Azure. It detects anomalies, generates optimization recommendations with ROI projections, produces showback reports per SRE team, and visualizes the cost vs. reliability trade-off to guide investment decisions.

---

## Story Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    Cloud Provider Cost Telemetry                        │
│  AWS (Cost Explorer API) │ GCP (Billing API) │ Azure (Cost Mgmt API)   │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    FINOPS-01: Anomaly Detection                         │
│                                                                         │
│  1. Compute 7-day trailing baseline per provider/region/service         │
│  2. Compare current cost metrics using z-score                          │
│  3. If z-score > threshold (default: 3), create anomaly alert           │
│  4. Trigger optimization scan automatically                             │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    FINOPS-02: Optimization Recommendations              │
│                                                                         │
│  1. Analyze resources across all providers and regions                  │
│  2. Generate recommendations: right-sizing, RI, spot, storage, unused   │
│  3. Calculate projected ROI: 30/60/90-day savings                       │
│  4. Score recommendations by ROI confidence (0-1)                       │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │
               ┌─────────────────┼─────────────────┐
               ▼                 ▼                  ▼
┌──────────────────────┐ ┌────────────────┐ ┌──────────────────────────┐
│  FINOPS-03: Showback │ │ Monthly Report │ │ FINOPS-04: Trade-off     │
│  Per team, service   │ │ Export (PDF/   │ │ Cost vs. Reliability     │
│  cost allocation     │ │ CSV)           │ │ Scatter plot + quadrants │
└──────────────────────┘ └────────────────┘ └──────────────────────────┘
```

---

## Story Details

### FINOPS-01: Real-Time Cloud Cost Anomaly Detection

**Anomaly Detection Algorithm:**

```python
# Simplified anomaly detection logic
import numpy as np

def detect_anomalies(cost_timeseries, threshold_std=3, baseline_days=7):
    """
    Detect cost anomalies using rolling z-score analysis.
    
    Args:
        cost_timeseries: DataFrame with columns [timestamp, provider, region, service, cost]
        threshold_std: Z-score threshold for anomaly classification
        baseline_days: Trailing window for baseline calculation
    
    Returns:
        List of anomalies with severity classification
    """
    results = []
    
    for (provider, region, service), group in cost_timeseries.groupby(['provider', 'region', 'service']):
        # Compute rolling statistics
        group['rolling_mean'] = group['cost'].rolling(window=f'{baseline_days}D', min_periods=1).mean()
        group['rolling_std'] = group['cost'].rolling(window=f'{baseline_days}D', min_periods=1).std()
        group['z_score'] = (group['cost'] - group['rolling_mean']) / group['rolling_std'].replace(0, np.nan)
        
        # Detect anomalies
        anomalies = group[group['z_score'].abs() > threshold_std]
        
        for _, row in anomalies.iterrows():
            severity = classify_severity(row['z_score'], row['cost'], row['rolling_mean'])
            results.append({
                'provider': provider,
                'region': region,
                'service': service,
                'current_value': row['cost'],
                'baseline_mean': row['rolling_mean'],
                'baseline_std_dev': row['rolling_std'],
                'z_score': row['z_score'],
                'deviation_pct': ((row['cost'] - row['rolling_mean']) / row['rolling_mean']) * 100,
                'severity': severity,
                'detected_at': row['timestamp']
            })
    
    return results

def classify_severity(z_score, current, baseline):
    deviation_pct = abs((current - baseline) / baseline) * 100
    if z_score > 5 or deviation_pct > 100:
        return 'critical'
    elif z_score > 4 or deviation_pct > 50:
        return 'high'
    elif z_score > 3 or deviation_pct > 25:
        return 'medium'
    else:
        return 'low'
```

**Acceptance Criteria:**
- ✅ Cost telemetry ingestion from AWS, GCP, Azure
- ✅ Per-region, per-service cost baseline from trailing 7-day window
- ✅ Dynamic thresholding using rolling statistics (mean, std dev, z-score)
- ✅ Anomaly alert triggers automated optimization scan
- ✅ Anomalies viewable in dashboard with drill-down

**Severity Classification:**

| Severity | Z-Score | Deviation | Action |
|----------|---------|-----------|--------|
| Critical | > 5 | > 100% | Immediate alert + auto-scan |
| High | > 4 | > 50% | Alert + schedule scan |
| Medium | > 3 | > 25% | Dashboard notification |
| Low | > 3 | < 25% | Logged for review |

---

### FINOPS-02: Automated Cost Optimization with Projected ROI

**Recommendation Types:**

| Category | Description | Example |
|----------|-------------|---------|
| **Right-sizing** | Resize over-provisioned resources | m5.xlarge → m5.large |
| **Reserved Instance** | Purchase RIs for steady-state workloads | 1-year standard RI |
| **Spot Instance** | Use spot instances for fault-tolerant workloads | EMR, batch jobs |
| **Storage Tiering** | Move cold data to cheaper storage tiers | S3 Standard → Glacier |
| **Unused Resource** | Identify and remove idle resources | Orphaned load balancers |
| **Commitment Discount** | Apply provider commitment discounts | GCP CUD, Azure RI |

**ROI Calculation:**

```
ROI Score = (Projected Monthly Savings - Implementation Cost) / Implementation Cost
           × Confidence Factor

Where:
  Confidence Factor = f(resource stability, usage pattern, provider discount availability)
  
Projections:
  30-day = Monthly Savings
  60-day = Monthly Savings × 2 × (1 - churn_probability)
  90-day = Monthly Savings × 3 × (1 - churn_probability)^2
```

**Acceptance Criteria:**
- ✅ Optimization scan is triggered by anomaly or on a schedule
- ✅ Recommendations include: resource ID, current cost, action, projected savings, complexity, ROI score
- ✅ ROI calculation includes implementation cost vs. projected savings
- ✅ Recommendations stored and queryable via API

---

### FINOPS-03: Showback/Show-Charge Reporting

**Report Structure:**

```
Showback Report: Payments SRE Team
Month: 2026-06
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Total Cost: $45,230.50

By Provider:
  AWS:   $28,450.00 (62.9%)
  GCP:   $10,230.50 (22.6%)
  Azure:  $6,550.00 (14.5%)

By Region:
  us-east-1:      $18,200.00 (40.2%)
  eu-west-1:      $15,230.50 (33.7%)
  ap-southeast-1: $11,800.00 (26.1%)

By Service:
  payment-service:     $18,200.00 (40.2%)
  fraud-detection:     $12,450.50 (27.5%)
  ledger-service:       $9,780.00 (21.6%)
  notification-service: $4,800.00 (10.6%)

Top 5 Cost Drivers:
  1. payment-db-prod (payment-service)   $8,200.00 (18.1%)
  2. fraud-ml-cluster (fraud-detection)  $6,500.00 (14.4%)
  3. ledger-cache-cluster (ledger)       $4,200.00 (9.3%)
  4. payment-api-mesh (payment-service)  $3,800.00 (8.4%)
  5. notification-queue (notification)   $2,100.00 (4.6%)

3-Month Trend:
  Apr 2026: $42,100.00
  May 2026: $43,800.00 (+4.0%)
  Jun 2026: $45,230.50 (+3.3%)
```

**Acceptance Criteria:**
- ✅ Cost allocation tags configurable per team, service, and environment
- ✅ Monthly showback auto-generated on billing cycle completion
- ✅ Report shows: total, provider breakdown, regional breakdown, 3-month trend, top 5 drivers
- ✅ Reports exportable as PDF, CSV, and viewable in dashboard

---

### FINOPS-04: Cost vs. Reliability Trade-off Dashboard

**Risk Quadrant Definitions:**

```
                    Error Budget Burn Rate
                    Low              High
               ┌──────────────────────────┐
          Low  │     Optimal       │  Under-funded  │
               │   (Invest more)  │  (Needs money)  │
Monthly Cost   ├──────────────────┼──────────────────┤
          High │  Over-engineered │    At-Risk      │
               │   (Cut costs)    │ (Critical!)     │
               └──────────────────────────────────────┘
```

**Quadrant Interpretation:**

| Quadrant | Cost | Burn Rate | Action |
|----------|------|-----------|--------|
| **Optimal** | Low | Low | Maintain. Consider investing more if SLO targets are conservative. |
| **Under-funded** | Low | High | Increase investment. Reliability is suffering due to insufficient resources. |
| **Over-engineered** | High | Low | Reduce spending. Resources are over-provisioned for current reliability needs. |
| **At-Risk** | High | High | Critical attention needed. Spending a lot but reliability is still poor. |

**Acceptance Criteria:**
- ✅ SLO and cost budget configurations are stored per service
- ✅ Scatter plot renders with monthly cost (x-axis) and error budget burn rate (y-axis)
- ✅ Risk quadrants are clearly labeled
- ✅ Clicking a service point shows detailed SLO and cost breakdown

---

## API Endpoints Summary

| Method | Path | Story | Description |
|--------|------|-------|-------------|
| `POST` | `/finops/anomalies/scan` | FINOPS-01 | Trigger cost anomaly scan |
| `GET` | `/finops/anomalies` | FINOPS-01 | List anomalies |
| `GET` | `/finops/anomalies/{id}` | FINOPS-01 | Get anomaly details |
| `GET` | `/finops/recommendations` | FINOPS-02 | List recommendations |
| `POST` | `/finops/recommendations` | FINOPS-02 | Trigger optimization scan |
| `PATCH` | `/finops/recommendations/{id}` | FINOPS-02 | Update recommendation status |
| `GET` | `/finops/showback` | FINOPS-03 | List showback reports |
| `GET` | `/finops/showback/current` | FINOPS-03 | Current month showback |
| `GET` | `/finops/showback/export` | FINOPS-03 | Export report |
| `GET` | `/finops/tradeoffs` | FINOPS-04 | Get trade-off data |
| `GET` | `/finops/tradeoffs/config` | FINOPS-04 | Get trade-off config |

---

## Implementation Tasks

| Task | Effort | Description |
|------|--------|-------------|
| FINOPS-01-T1 | 4d | Cost telemetry ingestion pipeline |
| FINOPS-01-T2 | 3d | Anomaly detection engine |
| FINOPS-01-T3 | 2d | Anomaly alerting pipeline |
| FINOPS-02-T1 | 4d | Optimization analysis engine |
| FINOPS-02-T2 | 2d | ROI projection calculator |
| FINOPS-02-T3 | 2d | Recommendations API |
| FINOPS-03-T1 | 2d | Cost allocation tag management |
| FINOPS-03-T2 | 3d | Monthly showback generator |
| FINOPS-03-T3 | 2d | Export service + dashboard widgets |
| FINOPS-04-T1 | 2d | SLO/cost budget config storage |
| FINOPS-04-T2 | 3d | Trade-off analytics engine |
| FINOPS-04-T3 | 3d | Scatter plot dashboard |

**Total Effort: 32 days**
