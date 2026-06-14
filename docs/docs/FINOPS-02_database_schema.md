# FINOPS-02: Automated Cost Optimization — Database Schema & Redis Configuration

## Overview

This document describes the database schema, seed data, and caching layer for the **FINOPS-02** feature — Automated Cost Optimization Recommendations with Projected ROI.

### Core Requirements

| Requirement | Implementation |
|---|---|
| Cost anomalies generate ROI-sorted recommendations | `finops_optimization_recommendations` with computed `roi_score` column, indexed for DESC sorting |
| Resource ID, current cost, projected savings, complexity | Columns `resource_id`, `current_monthly_cost`, `projected_monthly_savings`, `complexity` |
| GitOps PR template | `finops_remediation_templates` with `template_body` (YAML/HCL), `pr_title_template` |
| 24h debounce per resource | `finops_suppression_log` with `expires_at = suppressed_at + 24h`, UNIQUE partial index on active records |
| EU data residency | `finops_data_regions.is_eu_resident` flag; `finops_eu_recommendations` view; all queries MUST filter by region |

---

## Entity Relationship Diagram (text)

```
finops_data_regions
        |
        |--< finops_optimization_scans
        |       |
        |       |--< finops_optimization_recommendations
        |               |
        |               |--< finops_suppression_log
        |               |
        |               |--< finops_remediation_requests
        |                       |
        |                       |>-- finops_remediation_templates
```

---

## Tables

### 1. `finops_data_regions`
| Column | Type | Description |
|---|---|---|
| `id` | UUID PK | |
| `region_name` | VARCHAR(64) UNIQUE | e.g. `eu-west-1` |
| `provider` | VARCHAR(32) | `aws`, `azure`, `gcp` |
| `data_residency` | VARCHAR(8) | `EU`, `US`, `APAC` |
| `is_eu_resident` | BOOLEAN | **Critical flag** — TRUE = data must never leave EU |
| `is_active` | BOOLEAN | |

### 2. `finops_remediation_templates`
| Column | Type | Description |
|---|---|---|
| `template_key` | VARCHAR(128) UNIQUE | e.g. `ec2-rightsize-t3large` |
| `resource_type` | VARCHAR(64) | `EC2`, `RDS`, `EBS`, `Lambda`, `S3` |
| `complexity` | VARCHAR(16) | `low`, `medium`, `high` |
| `template_body` | TEXT | GitOps PR YAML/HCL/Terraform content |
| `pr_title_template` | VARCHAR(255) | Go-template string for PR titles |

### 3. `finops_optimization_scans`
| Column | Type | Description |
|---|---|---|
| `scan_name` | VARCHAR(255) | Human-readable scan name |
| `scan_type` | VARCHAR(32) | `scheduled`, `manual`, `anomaly_triggered`, `on_demand` |
| `status` | VARCHAR(32) | `running`, `completed`, `failed`, `partial` |
| `region_id` | UUID FK → `finops_data_regions` | Data boundary enforcement |
| `total_estimated_savings` | DECIMAL(12,2) | Sum of all recommendation savings |

### 4. `finops_optimization_recommendations`
| Column | Type | Description |
|---|---|---|
| `resource_id` | VARCHAR(255) | Cloud provider resource ARN/ID |
| `current_monthly_cost` | DECIMAL(12,4) | Current monthly spend |
| `projected_monthly_savings` | DECIMAL(12,4) | Projected monthly savings |
| `complexity` | VARCHAR(16) | `low`, `medium`, `high` |
| `roi_score` | DECIMAL(10,4) | **Computed**: `(savings/hours) * weight` where weight: low=3.0, med=1.5, high=1.0 |
| `status` | VARCHAR(32) | `open`, `dismissed`, `suppressed`, `in_progress`, `remediated`, `failed`, `reverted` |
| `verified_savings` | DECIMAL(12,4) | Actual savings after remediation (feedback loop) |

**Key Indexes:**
- `idx_finops_recs_status_roi` — partial index on `(status, roi_score DESC)` WHERE `status = 'open'`
- `idx_finops_recs_region_open_roi` — composite partial for EU-filtered listings

### 5. `finops_suppression_log`
| Column | Type | Description |
|---|---|---|
| `resource_id` + `recommendation_type` | Composite unique | One active suppression per pair |
| `expires_at` | TIMESTAMPTZ | `suppressed_at + 24h` |
| `is_active` | BOOLEAN (GENERATED) | `expires_at > NOW()` |

**Unique Index:** `uq_finops_suppression_active` — partial unique on `(resource_id, recommendation_type)` WHERE `is_active = TRUE`

### 6. `finops_remediation_requests`
| Column | Type | Description |
|---|---|---|
| `recommendation_id` | UUID FK → recommendations | |
| `pr_url` | VARCHAR(1024) | GitHub/GitLab merge request URL |
| `pr_status` | VARCHAR(32) | `draft`, `open`, `merged`, `closed`, `failed`, `conflict` |
| `merge_sha` | VARCHAR(64) | Git commit SHA after merge |
| `pipeline_status` | VARCHAR(32) | CI/CD pipeline result |

---

## Data Residency Enforcement

### EU Data Boundary Rule

All EU-resident regions are flagged with `is_eu_resident = TRUE` in `finops_data_regions`. The system **MUST** enforce the following:

1. **Read path**: Applications handling EU customer data MUST query via `finops_eu_recommendations` view OR add `WHERE region_id = ANY(finops_get_eu_region_ids())`
2. **Write path**: Recommendations for EU regions MUST be created with a EU-resident `region_id`
3. **Cache**: Redis instances serving EU regions MUST be in EU data centers

### Helper Functions

- `finops_get_eu_region_ids()` → Returns UUIDs of all EU-resident regions
- `finops_eu_recommendations` VIEW → All non-suppressed, open recommendations for EU regions

---

## Redis Cache Design

### Key Namespaces

| Namespace | Type | TTL | Purpose |
|---|---|---|---|
| `finops:recs:top:{region}` | ZSET | 300s | Top recommendations sorted by ROI |
| `finops:recs:detail:{id}` | HASH | 600s | Single recommendation detail |
| `finops:suppressed:{resource}:{type}` | STRING | Dynamic | Fast suppression check |
| `finops:scans:active:{region}` | HASH | 120s | Active scan status |
| `finops:recs:leaderboard` | ZSET | 600s | Cross-region ROI leaderboard |
| `finops:regions:eu` | SET | 3600s | EU region IDs (rarely changes) |
| `finops:dashboard:summary:{region}` | HASH | 120s | Dashboard aggregation cache |
| `finops:scans:rate:{resource}` | STRING | 86400s | Rate limiter for scan triggers |

### Eviction Policy

- `allkeys-lru` — least recently used eviction
- Max memory: 512MB
- Keys have explicit TTLs set by application

---

## Migration Files

| File | Description |
|---|---|
| `FINOPS-02_000_automated_cost_optimization.up.sql` | Create all 6 tables, indexes, functions, views |
| `FINOPS-02_000_automated_cost_optimization.down.sql` | Drop all FINOPS-02 objects in reverse dependency order |
| `FINOPS-02_000_cost_optimization_seed.sql` | Production-viable seed data with all entity types |
| `FINOPS-02_001_demo_more_recommendations.sql` | Supplementary demo recommendations |

---

## Seed Data Highlights

- **10 regions** across AWS, Azure, GCP (6 EU, 3 US, 1 APAC)
- **6 remediation templates** for EC2, RDS, EBS, Lambda, S3
- **3 optimization scans** covering scheduled, manual, and anomaly-triggered types
- **12 recommendations** with varied ROI scores, complexities, and statuses
- **2 suppression log entries** (1 active, 1 expired)
- **1 remediation request** (merged GitOps PR)
