

# FINOPS-03: Showback/Show-Charge Reporting — Database Schema Summary

## Overview

Schema for monthly showback (cost visibility) and show-charge (internal chargeback) reporting per SRE team, per service. Designed to satisfy data residency constraints (EU data stored only in EU zones), projected cost forecasting, and event-driven publication via transactional outbox.

## Entity-Relationship Diagram (Conceptual)

```
sre_teams 1──N services
sre_teams 1──N cost_allocations
services  1──N cost_allocations
cost_providers 1──N cost_regions
cost_providers 1──N cost_allocations
cost_regions   1──N cost_allocations

sre_teams 1──N showback_reports 1──N showback_report_line_items
sre_teams 1──N show_charge_reports 1──N show_charge_report_line_items

showback_reports  1──N report_publications
show_charge_reports 1──N report_publications
```

## Tables

### `sre_teams`
| Column | Type | Notes |
|--------|------|-------|
| id | UUID PK | Default gen_random_uuid() |
| name | VARCHAR(255) UNIQUE NOT NULL | e.g. "CloudSRE-Squadron" |
| description | TEXT | |
| cost_center_code | VARCHAR(50) UNIQUE | Finance cost center code |
| is_active | BOOLEAN | DEFAULT true |
| created_at | TIMESTAMPTZ | |
| updated_at | TIMESTAMPTZ | Auto-updated by trigger |

### `services`
| Column | Type | Notes |
|--------|------|-------|
| id | UUID PK | |
| name | VARCHAR(255) NOT NULL | |
| sre_team_id | UUID NOT NULL FK→sre_teams | |
| description | TEXT | |
| is_active | BOOLEAN | DEFAULT true |
| created_at | TIMESTAMPTZ | |
| updated_at | TIMESTAMPTZ | |

### `cost_providers`
| Column | Type | Notes |
|--------|------|-------|
| id | UUID PK | |
| name | VARCHAR(100) UNIQUE NOT NULL | 'AWS', 'Azure', 'GCP' |
| display_name | VARCHAR(255) | |
| is_active | BOOLEAN | DEFAULT true |
| created_at | TIMESTAMPTZ | |
| updated_at | TIMESTAMPTZ | |

### `cost_regions`
| Column | Type | Notes |
|--------|------|-------|
| id | UUID PK | |
| provider_id | UUID NOT NULL FK→cost_providers | |
| region_code | VARCHAR(50) NOT NULL | 'eu-west-1', 'us-east-1' |
| region_name | VARCHAR(255) | |
| data_residency_zone | VARCHAR(20) NOT NULL | 'EU', 'US', 'APAC', 'GLOBAL' |
| is_active | BOOLEAN | DEFAULT true |
| created_at | TIMESTAMPTZ | |
| updated_at | TIMESTAMPTZ | |

### `cost_allocations`
Raw monthly billing data allocated via tags.
| Column | Type | Notes |
|--------|------|-------|
| id | UUID PK | |
| billing_period | DATE NOT NULL | First day of billing month |
| provider_id | UUID NOT NULL FK→cost_providers | |
| region_id | UUID NOT NULL FK→cost_regions | |
| sre_team_id | UUID NOT NULL FK→sre_teams | |
| service_id | UUID FK→services | Nullable if unallocated |
| cost_amount | DECIMAL(18,6) NOT NULL | |
| currency | VARCHAR(3) DEFAULT 'USD' | |
| usage_quantity | DECIMAL(18,6) | |
| usage_unit | VARCHAR(50) | 'hours', 'GB', 'requests' |
| tag_hash | TEXT | MD5 of tag key:value pairs |
| data_residency_zone | VARCHAR(20) NOT NULL | Derived from region |
| metadata | JSONB | Flexible billing metadata |
| ingested_at | TIMESTAMPTZ DEFAULT NOW() | |
| created_at | TIMESTAMPTZ | |
| updated_at | TIMESTAMPTZ | |

### `showback_reports`
One report per team per month. Also holds projected costs.
| Column | Type | Notes |
|--------|------|-------|
| id | UUID PK | |
| sre_team_id | UUID NOT NULL FK→sre_teams | |
| billing_period | DATE NOT NULL | |
| total_cost | DECIMAL(18,2) NOT NULL | |
| currency | VARCHAR(3) DEFAULT 'USD' | |
| prior_month_total_cost | DECIMAL(18,2) | For trend |
| cost_trend_pct | DECIMAL(8,4) | (current - prior) / prior * 100 |
| projected_next_month_cost | DECIMAL(18,2) | Run-rate projection |
| report_type | VARCHAR(20) NOT NULL | 'showback' or 'show_charge' |
| status | VARCHAR(20) DEFAULT 'draft' | 'draft', 'final', 'published' |
| generated_at | TIMESTAMPTZ DEFAULT NOW() | |
| created_at | TIMESTAMPTZ | |
| updated_at | TIMESTAMPTZ | |

### `showback_report_line_items`
Breakdown by provider, region, or service.
| Column | Type | Notes |
|--------|------|-------|
| id | UUID PK | |
| report_id | UUID NOT NULL FK→showback_reports ON DELETE CASCADE | |
| breakdown_type | VARCHAR(20) NOT NULL | 'provider', 'region', 'service' |
| breakdown_id | UUID NOT NULL | FK to respective table |
| cost_amount | DECIMAL(18,2) NOT NULL | |
| percentage_of_total | DECIMAL(8,4) | |
| prior_month_cost | DECIMAL(18,2) | |
| trend_pct | DECIMAL(8,4) | |
| projected_cost | DECIMAL(18,2) | |
| metadata | JSONB | |
| created_at | TIMESTAMPTZ | |

### `show_charge_reports`
Similar to showback but includes chargeback multiplier for internal billing.
| Column | Type | Notes |
|--------|------|-------|
| id | UUID PK | |
| sre_team_id | UUID NOT NULL FK→sre_teams | |
| billing_period | DATE NOT NULL | |
| total_cost | DECIMAL(18,2) NOT NULL | |
| currency | VARCHAR(3) DEFAULT 'USD' | |
| prior_month_total_cost | DECIMAL(18,2) | |
| cost_trend_pct | DECIMAL(8,4) | |
| projected_next_month_cost | DECIMAL(18,2) | |
| chargeback_rate_multiplier | DECIMAL(10,6) DEFAULT 1.0 | Overhead multiplier |
| chargeback_total | DECIMAL(18,2) | total_cost × multiplier |
| status | VARCHAR(20) DEFAULT 'draft' | |
| generated_at | TIMESTAMPTZ | |
| created_at | TIMESTAMPTZ | |
| updated_at | TIMESTAMPTZ | |

### `show_charge_report_line_items`
| Column | Type | Notes |
|--------|------|-------|
| id | UUID PK | |
| charge_report_id | UUID NOT NULL FK→show_charge_reports ON DELETE CASCADE | |
| breakdown_type | VARCHAR(20) NOT NULL | |
| breakdown_id | UUID NOT NULL | |
| cost_amount | DECIMAL(18,2) NOT NULL | |
| chargeback_amount | DECIMAL(18,2) | cost × multiplier |
| prior_month_cost | DECIMAL(18,2) | |
| trend_pct | DECIMAL(8,4) | |
| projected_cost | DECIMAL(18,2) | |
| metadata | JSONB | |
| created_at | TIMESTAMPTZ | |

### `report_publications`
Tracks published reports available via API/CSV/PDF.
| Column | Type | Notes |
|--------|------|-------|
| id | UUID PK | |
| report_type | VARCHAR(20) NOT NULL | 'showback', 'show_charge' |
| report_id | UUID NOT NULL | FK polymorphic |
| published_at | TIMESTAMPTZ DEFAULT NOW() | |
| published_by | VARCHAR(255) | |
| format | VARCHAR(10) NOT NULL | 'api', 'csv', 'pdf' |
| download_url | TEXT | Signed URL for CSV/PDF |
| expires_at | TIMESTAMPTZ | URL expiry |
| created_at | TIMESTAMPTZ | |

### `data_residency_rules`
| Column | Type | Notes |
|--------|------|-------|
| id | UUID PK | |
| region_code_pattern | VARCHAR(100) NOT NULL | e.g. 'eu-%', 'us-%' |
| allowed_database_zone | VARCHAR(50) NOT NULL | 'eu-db', 'us-db' |
| is_enabled | BOOLEAN DEFAULT true | |
| created_at | TIMESTAMPTZ | |
| updated_at | TIMESTAMPTZ | |

### `outbox_events`
Transactional outbox for reliable event publishing.
| Column | Type | Notes |
|--------|------|-------|
| id | UUID PK | |
| event_type | VARCHAR(255) NOT NULL | 'finops.ShowbackReportGenerated' |
| aggregate_type | VARCHAR(100) NOT NULL | 'showback_report', 'show_charge_report' |
| aggregate_id | UUID NOT NULL | |
| payload | JSONB NOT NULL | Full event payload |
| published | BOOLEAN DEFAULT false | |
| published_at | TIMESTAMPTZ | |
| created_at | TIMESTAMPTZ | |

### `cost_forecasts`
Monthly projected costs based on run-rate.
| Column | Type | Notes |
|--------|------|-------|
| id | UUID PK | |
| sre_team_id | UUID NOT NULL FK→sre_teams | |
| service_id | UUID FK→services | Nullable for team-level |
| forecast_date | DATE NOT NULL | Target month |
| projected_cost | DECIMAL(18,2) NOT NULL | |
| confidence_lower | DECIMAL(18,2) | |
| confidence_upper | DECIMAL(18,2) | |
| model_version | VARCHAR(50) | 'run-rate-v1', 'ml-v2' |
| created_at | TIMESTAMPTZ | |

## Indexes

- `cost_allocations`: (billing_period, sre_team_id, provider_id, region_id, service_id)
- `cost_allocations`: (data_residency_zone)
- `showback_reports`: (sre_team_id, billing_period)
- `show_charge_reports`: (sre_team_id, billing_period)
- `outbox_events`: (published, created_at) for publisher worker
- `report_publications`: (report_type, report_id)
- `cost_forecasts`: (sre_team_id, forecast_date)

## Data Residency Strategy

- `cost_regions.data_residency_zone` determines where data belongs.
- EU-cost data (`eu-*` regions) is only stored in EU database instances.
- A partition or separate DB instance check is enforced by application layer plus DB row-level filtering via `data_residency_zone` columns.
- `data_residency_rules` table maps region patterns to allowed database zones.

## Events (Transactional Outbox)

| Event | Trigger | Payload |
|-------|---------|---------|
| finops.ShowbackReportGenerated | Report finalized | report_id, team_id, period, total_cost, download_urls |
| finops.ShowChargeReportGenerated | Charge report finalized | charge_report_id, team_id, period, total_cost, chargeback_total |
| finops.ReportsPublished | Report published to API | report_type, report_id, formats[], published_at |
