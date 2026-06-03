

# FINOPS-03: Showback/Show-Charge Report API Specification
# ==========================================================
# The reports are available via REST API and as downloadable CSV/PDF.

## Base URL
`/api/v1/finops/reports`

## Authentication
All endpoints require authentication via Bearer token or OAuth2.0.
Standard RBAC roles: `finops.viewer`, `finops.admin`, `org.admin`

## Endpoints

### 1. List Showback Reports
```
GET /api/v1/finops/reports/showback
```
**Query Parameters:**
| Parameter    | Type   | Description                                      |
|-------------|--------|--------------------------------------------------|
| team_id     | UUID   | Filter by SRE team                               |
| period_from | DATE   | Start of billing period range (YYYY-MM-01)       |
| period_to   | DATE   | End of billing period range (YYYY-MM-01)         |
| status      | string | draft, final, published                          |
| page        | int    | Page number (default: 1)                         |
| page_size   | int    | Items per page (default: 20, max: 100)           |

**Response (200):**
```json
{
  "data": [
    {
      "id": "uuid",
      "sre_team": {
        "id": "uuid",
        "name": "CloudSRE-Squadron",
        "cost_center_code": "CC-CLOUD-001"
      },
      "billing_period": "2026-06-01",
      "total_cost": 152340.50,
      "currency": "USD",
      "prior_month_total_cost": 148200.00,
      "cost_trend_pct": 2.79,
      "projected_next_month_cost": 158000.00,
      "status": "published",
      "generated_at": "2026-06-01T02:00:00Z",
      "downloads": {
        "csv": "/api/v1/finops/reports/showback/{id}/download?format=csv",
        "pdf": "/api/v1/finops/reports/showback/{id}/download?format=pdf"
      }
    }
  ],
  "pagination": {
    "page": 1,
    "page_size": 20,
    "total_items": 5,
    "total_pages": 1
  }
}
```

### 2. Get Showback Report Detail
```
GET /api/v1/finops/reports/showback/{report_id}
```
Returns the full report with all breakdowns (by provider, region, service).

**Response (200):**
```json
{
  "id": "uuid",
  "sre_team": { ... },
  "billing_period": "2026-06-01",
  "total_cost": 152340.50,
  "cost_trend_pct": 2.79,
  "projected_next_month_cost": 158000.00,
  "breakdown_by_provider": [
    {
      "provider_id": "uuid",
      "provider_name": "AWS",
      "cost": 85000.00,
      "percentage": 55.8,
      "prior_month_cost": 82000.00,
      "trend_pct": 3.66,
      "projected_cost": 88000.00
    },
    {
      "provider_id": "uuid",
      "provider_name": "Azure",
      "cost": 45000.00,
      "percentage": 29.5,
      "prior_month_cost": 44000.00,
      "trend_pct": 2.27,
      "projected_cost": 47000.00
    },
    {
      "provider_id": "uuid",
      "provider_name": "GCP",
      "cost": 22340.50,
      "percentage": 14.7,
      "prior_month_cost": 22200.00,
      "trend_pct": 0.63,
      "projected_cost": 23000.00
    }
  ],
  "breakdown_by_region": [
    {
      "region_id": "uuid",
      "region_code": "us-east-1",
      "region_name": "US East (N. Virginia)",
      "data_residency_zone": "US",
      "cost": 65000.00,
      "percentage": 42.7,
      "trend_pct": 1.2,
      "projected_cost": 67000.00
    },
    {
      "region_id": "uuid",
      "region_code": "eu-west-1",
      "region_name": "EU West (Ireland)",
      "data_residency_zone": "EU",
      "cost": 42000.00,
      "percentage": 27.6,
      "trend_pct": 3.1,
      "projected_cost": 44000.00
    }
  ],
  "breakdown_by_service": [
    {
      "service_id": "uuid",
      "service_name": "Compute Engine",
      "cost": 72000.00,
      "percentage": 47.3,
      "trend_pct": 2.5,
      "projected_cost": 75000.00
    }
  ]
}
```

### 3. List Show-Charge Reports
```
GET /api/v1/finops/reports/charge
```
Same query parameters and structure as showback reports, but includes `chargeback_rate_multiplier` and `chargeback_total`.

### 4. Get Show-Charge Report Detail
```
GET /api/v1/finops/reports/charge/{charge_report_id}
```

### 5. Download Report as CSV/PDF
```
GET /api/v1/finops/reports/{type}/{report_id}/download?format={csv|pdf}
```
Generates and returns a downloadable file. Reports are temporarily cached (TTL matches signed URL expiry).

### 6. Get Report Publications
```
GET /api/v1/finops/reports/{type}/{report_id}/publications
```
Returns all published versions of a report with download URLs and expiry dates.

### 7. Generate Report (On-Demand)
```
POST /api/v1/finops/reports/{type}/generate
```
Triggers generation of a report for a given team and period. Returns 202 Accepted with job ID.
Requires `finops.admin` role.

**Request Body:**
```json
{
  "sre_team_id": "uuid",
  "billing_period": "2026-06-01",
  "report_type": "showback",
  "chargeback_rate_multiplier": null
}
```

## Event-Driven Architecture

When reports are generated and published, events are emitted via the transactional outbox:

| Event | Trigger | Consumer |
|-------|---------|----------|
| `finops.ShowbackReportGenerated` | Report finalized to 'published' status | Notification service, Slack webhook |
| `finops.ShowChargeReportGenerated` | Charge report finalized | Internal billing system, notification service |
| `finops.ReportsPublished` | Report made available via API | Audit log, compliance tracker, dashboard update |

## Data Residency Enforcement

- The `data_residency_zone` column on `cost_regions` and `cost_allocations` determines storage location.
- EU region data (zone = 'EU') is routed to EU database clusters.
- The `data_residency_rules` table is consulted at the application layer before write operations.
- Reports spanning multiple zones are assembled by the application layer from the appropriate database instances.
- API responses filter out EU data when requested from non-EU endpoints unless explicitly authorized.

## Caching Strategy

- **Redis** caches report JSON payloads with 24h TTL (reports change once per month).
- Cost aggregation queries are cached for 1h to support interactive exploration without recomputing.
- CSV/PDF downloads are generated on first request and cached at the CDN level.
- Cache invalidation occurs on: report regeneration, new billing data ingestion, manual admin trigger.
