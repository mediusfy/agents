# Rufkis SRE Platform — API Reference

> **Base URL**: `https://api.rufkis.io/v1`  
> **OpenAPI Spec**: [`openapi.yaml`](openapi.yaml)  
> **Content-Type**: `application/json`

---

## Table of Contents

1. [Authentication](#authentication)
2. [Common Patterns](#common-patterns)
3. [GitOps - Remediations](#1-gitops---remediations)
4. [GitOps - Runbooks](#2-gitops---runbooks)
5. [GitOps - Audit](#3-gitops---audit)
6. [GitOps - Policies](#4-gitops---policies)
7. [FinOps - Anomalies](#5-finops---anomalies)
8. [FinOps - Recommendations](#6-finops---recommendations)
9. [FinOps - Showback](#7-finops---showback)
10. [FinOps - Tradeoffs](#8-finops---tradeoffs)
11. [Triage - Classification](#9-triage---classification)
12. [Triage - RCA](#10-triage---rca)
13. [Triage - Self-Healing](#11-triage---self-healing)
14. [Triage - Escalation](#12-triage---escalation)
15. [Workspace - Sync](#13-workspace---sync)
16. [Workspace - P2P](#14-workspace---p2p)
17. [Error Codes](#error-codes)
18. [Rate Limiting](#rate-limiting)

---

## Authentication

All API requests require authentication via Bearer token in the `Authorization` header.

```http
Authorization: Bearer <your_api_token>
```

Tokens are issued per workspace and scoped to specific capabilities (e.g., `gitops:write`, `finops:read`).

**Header-based authentication example:**

```bash
curl -H "Authorization: Bearer rfk_abc123def456" \
     https://api.rufkis.io/v1/health
```

---

## Common Patterns

### Pagination

List endpoints support `limit` and `offset` parameters:

| Parameter | Type | Default | Max |
|-----------|------|---------|-----|
| `limit` | integer | 20 | 100 |
| `offset` | integer | 0 | — |

**Response shape:**

```json
{
  "items": [ ... ],
  "total": 57,
  "limit": 20,
  "offset": 0
}
```

### Error Response

```json
{
  "error": "remediation_not_found",
  "message": "Remediation with ID abc-123 not found",
  "details": { "remediation_id": "abc-123" },
  "request_id": "req-uuid-here"
}
```

### Idempotency

POST endpoints that create resources support idempotency via `Idempotency-Key` header.

```http
Idempotency-Key: unique-key-for-retry
```

---

## 1. GitOps - Remediations

Automated incident response via GitOps pull requests.

### POST `/gitops/remediations`

Create a remediation PR for an incident.

**Request:**

```json
{
  "incident_id": "inc-20260603-001",
  "runbook_id": "rb-database-failover",
  "environment": "production",
  "region": "us-east-1",
  "variables": {
    "db_cluster": "prod-db-01",
    "failover_target": "us-east-1b"
  }
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `incident_id` | string | ✅ | Unique incident identifier |
| `runbook_id` | string | ✅ | Runbook to execute |
| `environment` | string | ✅ | `production`, `staging`, or `development` |
| `region` | string | | Cloud region |
| `variables` | object | | Runbook template variables |

**Response `201`:**

```json
{
  "id": "rem-abc123",
  "incident_id": "inc-20260603-001",
  "runbook_id": "rb-database-failover",
  "environment": "production",
  "region": "us-east-1",
  "pr_url": "https://github.com/mediusfy/platform/pull/42",
  "pr_number": 42,
  "repository": "rufkis/runbooks",
  "branch": "remediation/inc-20260603-001-rb-database-failover",
  "status": "pending",
  "created_by": "triage-agent-v2",
  "created_at": "2026-06-03T02:25:00Z",
  "diff_summary": "Updated database failover configuration for prod-db-01"
}
```

### GET `/gitops/remediations`

List remediation PRs with optional filters.

**Query Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `incident_id` | string | Filter by incident |
| `status` | enum | `pending`, `approved`, `merged`, `rejected`, `rolled_back` |
| `limit` | integer | Max results (default: 20) |
| `offset` | integer | Pagination offset |

### GET `/gitops/remediations/{remediation_id}`

Get detailed information about a specific remediation PR.

### POST `/gitops/remediations/{remediation_id}/rollback`

Create a revert PR for a previously merged remediation.

**Request:**

```json
{
  "reason": "Failover caused increased latency in downstream services",
  "requested_by": "sre-alice"
}
```

---

## 2. GitOps - Runbooks

Declarative runbook definitions stored in Git.

### GET `/gitops/runbooks`

List runbooks with optional filters.

**Query Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `service` | string | Filter by service name |
| `severity` | enum | `P0`, `P1`, `P2`, `P3`, `P4` |
| `environment` | enum | `production`, `staging`, `development` |

### GET `/gitops/runbooks/{runbook_id}`

Get a runbook's full definition including trigger conditions, steps, rollback procedure, and approval requirements.

### POST `/gitops/runbooks/validate`

Validate a runbook YAML definition against the runbook schema.

**Request:**

```json
{
  "runbook_yaml": "name: database-failover\nservice: database\nseverity:\n  - P0\n  - P1\ntrigger_conditions:\n  metric: database_connection_errors\n  operator: gt\n  threshold: 100\n  duration_seconds: 300\nsteps:\n  - step_number: 1\n    name: Identify primary\n    action: execute_query\n    parameters:\n      query: \"SHOW PRIMARY\"\n"
}
```

**Response `200`:**

```json
{
  "valid": true,
  "errors": [],
  "warnings": [
    "Rollback procedure not defined for step 3"
  ]
}
```

### Runbook YAML Schema

Runbooks follow this structure:

```yaml
name: string                    # Required: unique runbook name
description: string             # Required: what this runbook does
version: string                 # Required: semver
service: string                 # Required: service this applies to
severity: [P0..P4]              # Required: applicable severity levels
environments: [production..]    # Required: applicable environments

trigger_conditions:             # Required when used for auto-remediation
  metric: string
  operator: gt|lt|gte|lte|eq
  threshold: number
  duration_seconds: integer

steps:                          # Required: ordered remediation steps
  - step_number: integer
    name: string
    action: string              # Action type (execute_query, run_script, api_call, etc.)
    parameters: {}
    rollback_step: string       # Reference to rollback step

rollback_procedure:             # Required
  steps:
    - step_number: integer
      name: string
      action: string
      parameters: {}
  estimated_time_seconds: integer

approval_requirements:          # Required
  min_approvers: integer        # Default: 1 for P3+, 2 for P0-P1 prod
  required_roles: [string]      # e.g., ["sre", "team-lead"]
  auto_approve: boolean         # For low-severity, non-prod changes
```

---

## 3. GitOps - Audit

Audit trail and rollback via Git history.

### GET `/gitops/audit`

Query the remediation audit trail with filters.

**Query Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `incident_id` | string | Filter by incident |
| `start_date` | datetime | Start of date range |
| `end_date` | datetime | End of date range |
| `approver` | string | Filter by approver name |
| `service` | string | Filter by service |

**Response:**

```json
{
  "items": [
    {
      "id": "aud-001",
      "incident_id": "inc-20260603-001",
      "remediation_id": "rem-abc123",
      "action": "pr_merged",
      "actor": "sre-bob",
      "actor_type": "user",
      "timestamp": "2026-06-03T02:30:00Z",
      "details": {
        "approval_required": 2,
        "approvers": ["sre-bob", "sre-lead-charlie"]
      },
      "git_commit_sha": "a1b2c3d4e5f6..."
    }
  ],
  "total": 1
}
```

### GET `/gitops/audit/{incident_id}`

Get the complete audit history for a specific incident, including all Git commit data.

**Response:**

```json
{
  "incident_id": "inc-20260603-001",
  "entries": [ ... ],
  "git_history": [
    {
      "commit_sha": "a1b2c3d4e5f6...",
      "author": "sre-bob",
      "committer": "GitOps Bot",
      "message": "remediation(inc-20260603-001): database failover for prod-db-01",
      "timestamp": "2026-06-03T02:30:00Z",
      "files_changed": ["runbooks/database/failover.yaml"],
      "additions": 15,
      "deletions": 3
    }
  ]
}
```

---

## 4. GitOps - Policies

Policy-as-Code for remediation approval gates.

### POST `/gitops/policies/evaluate`

Evaluate a PR against all defined policies.

**Request:**

```json
{
  "pr_id": 42,
  "repository": "rufkis/runbooks",
  "branch": "remediation/inc-001",
  "severity": "P0",
  "service": "payment-service",
  "environment": "production",
  "changed_files": ["runbooks/database/failover.yaml"]
}
```

**Response:**

```json
{
  "passed": false,
  "required_approvers": [
    {
      "user_id": "sre-lead-charlie",
      "role": "sre-lead",
      "required": true
    },
    {
      "user_id": "sre-bob",
      "role": "sre-engineer",
      "required": true
    }
  ],
  "policies_evaluated": [
    {
      "policy_id": "approval-p0-prod",
      "name": "P0 Production Changes Require Two Approvers",
      "result": "fail",
      "message": "Only 0 of 2 required approvers have approved. SRE lead approval is mandatory for P0 production changes."
    }
  ],
  "tags": ["requires-sre-lead", "production", "p0"],
  "summary": "2 approvers required: 1 SRE engineer + 1 SRE lead"
}
```

### GET `/gitops/policies`

List all defined policies with their Rego source.

---

## 5. FinOps - Anomalies

Real-time cloud cost anomaly detection per region per provider.

### POST `/finops/anomalies/scan`

Trigger a cost anomaly scan across providers and regions.

**Request:**

```json
{
  "providers": ["aws", "gcp", "azure"],
  "regions": ["eu-west-1", "us-east-1", "ap-southeast-1"],
  "baseline_days": 7,
  "threshold_std_dev": 3
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `providers` | array | all | Cloud providers to scan |
| `regions` | array | all | Regions to scan |
| `baseline_days` | integer | 7 | Trailing window for baseline calculation |
| `threshold_std_dev` | number | 3 | Z-score threshold for anomaly detection |

**Response:**

```json
{
  "scan_id": "scan-001",
  "anomalies_found": 3,
  "anomalies": [
    {
      "id": "anom-001",
      "provider": "aws",
      "region": "us-east-1",
      "service": "EC2",
      "metric_name": "total_cost",
      "current_value": 45230.50,
      "baseline_mean": 32100.00,
      "baseline_std_dev": 3200.00,
      "z_score": 4.1,
      "deviation_pct": 40.9,
      "severity": "critical",
      "status": "open",
      "detected_at": "2026-06-03T02:25:00Z",
      "resource_ids": ["i-abc123", "i-def456"],
      "cost_impact_daily": 437.67
    }
  ],
  "scan_completed_at": "2026-06-03T02:25:30Z"
}
```

### GET `/finops/anomalies`

List anomalies with filters.

**Query Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `provider` | enum | `aws`, `gcp`, `azure` |
| `region` | string | Cloud region |
| `status` | enum | `open`, `acknowledged`, `resolved`, `false_positive` |
| `severity` | enum | `critical`, `high`, `medium`, `low` |

### GET `/finops/anomalies/{anomaly_id}`

Get detailed anomaly information including per-resource breakdown.

---

## 6. FinOps - Recommendations

Automated cost optimization recommendations with projected ROI.

### GET `/finops/recommendations`

List cost optimization recommendations.

**Query Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `provider` | enum | `aws`, `gcp`, `azure` |
| `status` | enum | `pending`, `implemented`, `dismissed` |
| `min_roi_score` | number | Minimum ROI score filter (0–1) |
| `sort_by` | enum | `projected_savings`, `roi_score`, `complexity` |

**Response:**

```json
{
  "items": [
    {
      "id": "rec-001",
      "provider": "aws",
      "region": "us-east-1",
      "resource_id": "i-abc123",
      "resource_type": "EC2",
      "current_cost_monthly": 2450.00,
      "recommended_action": "Resize from m5.xlarge to m5.large",
      "action_category": "right_sizing",
      "projected_savings_monthly": 1225.00,
      "implementation_cost": 0,
      "roi_score": 0.95,
      "roi_30day": 1225.00,
      "roi_60day": 2450.00,
      "roi_90day": 3675.00,
      "complexity": "low",
      "status": "pending",
      "generated_at": "2026-06-03T02:25:00Z"
    }
  ],
  "total": 15,
  "total_projected_savings_monthly": 12450.00
}
```

### POST `/finops/recommendations`

Trigger a new optimization scan.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `providers` | array | all | Providers to scan |
| `regions` | array | all | Regions to scan |
| `scan_type` | enum | `incremental` | `full` or `incremental` |

### PATCH `/finops/recommendations/{recommendation_id}`

Update recommendation status.

```json
{
  "status": "implemented",
  "notes": "Resized instance. Savings confirmed."
}
```

---

## 7. FinOps - Showback

Showback/show-charge reporting per SRE team per service.

### GET `/finops/showback`

List showback reports.

**Query Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `team_id` | string | Filter by team |
| `service_id` | string | Filter by service |
| `billing_month` | string | Filter by month (`YYYY-MM`) |

### GET `/finops/showback/current`

Get the current month's showback summary for a team.

**Response:**

```json
{
  "id": "sb-2026-06",
  "team_id": "team-sre-payments",
  "team_name": "Payments SRE",
  "billing_month": "2026-06",
  "generated_at": "2026-06-01T00:00:00Z",
  "total_cost": 45230.50,
  "cost_by_provider": {
    "aws": 28450.00,
    "gcp": 10230.50,
    "azure": 6550.00
  },
  "cost_by_region": {
    "us-east-1": 18200.00,
    "eu-west-1": 15230.50,
    "ap-southeast-1": 11800.00
  },
  "cost_by_service": {
    "payment-service": 18200.00,
    "fraud-detection": 12450.50,
    "ledger-service": 9780.00,
    "notification-service": 4800.00
  },
  "cost_trend": [
    { "month": "2026-04", "cost": 42100.00 },
    { "month": "2026-05", "cost": 43800.00 },
    { "month": "2026-06", "cost": 45230.50 }
  ],
  "top_cost_drivers": [
    {
      "resource_id": "payment-db-prod",
      "service": "payment-service",
      "cost": 8200.00,
      "pct_of_total": 18.1
    }
  ]
}
```

### GET `/finops/showback/export`

Export a showback report as PDF or CSV.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `report_id` | string | — | Report identifier |
| `format` | enum | `csv` | `pdf` or `csv` |

---

## 8. FinOps - Tradeoffs

Cost vs. reliability trade-off visualization.

### GET `/finops/tradeoffs`

Get cost vs. reliability data points for all services.

**Query Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `start_date` | date | Start of analysis period |
| `end_date` | date | End of analysis period |
| `services` | array | Filter by service names |

**Response:**

```json
{
  "data_points": [
    {
      "service": "payment-service",
      "monthly_cost": 18200.00,
      "error_budget_burn_rate": 0.15,
      "slo_target": 99.95,
      "current_sli": 99.92,
      "quadrant": "optimal",
      "cost_budget": 20000.00,
      "cost_variance_pct": -9.0
    }
  ],
  "quadrants": {
    "under_funded": ["notification-service"],
    "optimal": ["payment-service", "ledger-service"],
    "over_engineered": ["fraud-detection"],
    "at_risk": ["user-auth-service"]
  }
}
```

### Quadrant Definitions

| Quadrant | Description |
|----------|-------------|
| **Under-funded** | Low cost, high error budget burn — needs investment |
| **Optimal** | Balanced cost and reliability |
| **Over-engineered** | High cost, low burn — can reduce spending |
| **At-risk** | High cost, high burn — critical attention needed |

### GET `/finops/tradeoffs/config`

Get SLO and cost budget configurations for all services.

### POST `/finops/tradeoffs/config`

Create or update trade-off configuration for a service.

```json
{
  "service": "payment-service",
  "slo_target": 99.95,
  "cost_budget_monthly": 20000.00,
  "cost_budget_currency": "USD",
  "error_budget_period_days": 30,
  "risk_tolerance": "low",
  "tags": {
    "tier": "critical",
    "team": "payments-sre"
  }
}
```

---

## 9. Triage - Classification

AI-powered incident triage for severity and ownership classification.

### POST `/triage/classify`

Classify an incident with AI-powered severity and ownership determination.

**Request:**

```json
{
  "alert_id": "alt-20260603-042",
  "source": "prometheus",
  "title": "High error rate on payment-service",
  "description": "HTTP 500 errors exceeding 5% in the last 5 minutes on payment-service instances. Current rate: 5.7%, threshold: 1.0%",
  "raw_payload": {
    "service": "payment-service",
    "namespace": "production",
    "metric": "http_requests_error_rate",
    "value": 5.7,
    "threshold": 1.0,
    "instance": "payment-service-abc123"
  },
  "source_url": "https://prometheus.example.com/alerts/abc123",
  "labels": {
    "severity": "critical",
    "team": "payments"
  }
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `alert_id` | string | ✅ | Source alert/incident identifier |
| `source` | string | ✅ | `prometheus`, `datadog`, `grafana`, `cloudwatch`, `azure_monitor`, `webhook`, `manual` |
| `title` | string | ✅ | Alert title (max 500 chars) |
| `description` | string | ✅ | Detailed description (max 5000 chars) |
| `raw_payload` | object | | Full raw payload for deep analysis |
| `source_url` | string | | Link to original alert |
| `labels` | object | | Alert metadata labels |

**Response `200`:**

```json
{
  "id": "cl-abc123",
  "alert_id": "alt-20260603-042",
  "severity": "P0",
  "severity_confidence": 0.97,
  "severity_rationale": "Production payment service experiencing >5% error rate, exceeding P0 threshold of 1%. Customer-impacting transaction failures imminent.",
  "assigned_team": "payments-sre",
  "assigned_team_confidence": 0.94,
  "alternative_teams": [
    { "team": "platform-sre", "confidence": 0.05 },
    { "team": "infra-sre", "confidence": 0.01 }
  ],
  "suggested_runbooks": ["rb-payment-high-errors", "rb-database-connection-pool"],
  "classification_model": "rufkis-triage-v2.3",
  "classified_at": "2026-06-03T02:25:00Z",
  "processing_time_ms": 342
}
```

### GET `/triage/classifications/{classification_id}`

Get details of a previous classification.

---

## 10. Triage - RCA

Automated root cause analysis suggestions.

### POST `/triage/rca`

Trigger a root cause analysis for a classified incident.

**Request:**

```json
{
  "incident_id": "inc-20260603-001",
  "classification_id": "cl-abc123",
  "context": {
    "time_range_minutes": 60,
    "include_logs": true,
    "include_metrics": true,
    "include_traces": true,
    "include_recent_changes": true
  }
}
```

**Response `200`:**

```json
{
  "incident_id": "inc-20260603-001",
  "analysis_id": "rca-001",
  "status": "completed",
  "root_causes": [
    {
      "rank": 1,
      "title": "Database connection pool exhaustion",
      "description": "The payment-service database connection pool reached maximum capacity (200 connections) due to a recent deployment that increased connection-per-request ratio.",
      "confidence": 0.88,
      "evidence": [
        {
          "source": "logs",
          "snippet": "ERROR: could not acquire connection from pool - pool exhausted (max: 200, active: 200, idle: 0)",
          "timestamp": "2026-06-03T02:20:15Z",
          "severity": "error"
        },
        {
          "source": "metrics",
          "snippet": "db_connections_active: 200 (breached threshold of 180)",
          "timestamp": "2026-06-03T02:20:00Z",
          "severity": "critical"
        },
        {
          "source": "git_changes",
          "snippet": "commit a1b2c3d: Increased connection pool size in config, but connection leak introduced in pool release logic",
          "timestamp": "2026-06-02T15:00:00Z",
          "severity": "high"
        }
      ],
      "suggested_remediation": "Increase max pool size to 300 temporarily, rollback recent config change, and fix connection release logic",
      "related_runbooks": ["rb-database-connection-pool", "rb-payment-high-errors"]
    }
  ],
  "analysis_metadata": {
    "context_window_minutes": 60,
    "sources_analyzed": ["logs", "metrics", "traces", "git_changes"],
    "log_lines_analyzed": 15000,
    "trace_spans_analyzed": 2500,
    "changes_reviewed": 3,
    "processing_time_ms": 4520,
    "model_version": "rufkis-rca-v1.5"
  }
}
```

### GET `/triage/rca/{incident_id}`

Get RCA results for a specific incident.

---

## 11. Triage - Self-Healing

Self-healing runbook execution via autonomous agents.

### POST `/triage/self-healing/execute`

Execute a self-healing runbook for a classified incident.

**Request:**

```json
{
  "incident_id": "inc-20260603-001",
  "classification_id": "cl-abc123",
  "dry_run": true
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `dry_run` | boolean | `true` | Execute dry-run first before actual remediation. Set to `false` to proceed with live execution after dry-run passes. |

**Response `200`:**

```json
{
  "execution_id": "sh-001",
  "incident_id": "inc-20260603-001",
  "status": "dry_run_completed",
  "runbook_id": "rb-database-connection-pool",
  "match_confidence": 0.94,
  "dry_run_results": {
    "passed": true,
    "steps_executed": 4,
    "steps_failed": 0,
    "details": [
      { "step": 1, "name": "Check current pool size", "result": "passed" },
      { "step": 2, "name": "Validate connection release logic", "result": "passed" },
      { "step": 3, "name": "Test pool resize operation", "result": "passed" },
      { "step": 4, "name": "Verify rollback procedure", "result": "passed" }
    ]
  },
  "remediation_pr": {
    "pr_url": "https://github.com/mediusfy/platform/pull/43",
    "status": "pending"
  },
  "rollback_plan": {
    "steps": [
      { "name": "Revert pool size to original value", "action": "update_config" }
    ],
    "estimated_time_seconds": 30
  },
  "timeline_entries": [
    {
      "type": "self_healing_started",
      "message": "Self-healing agent initiated for incident inc-20260603-001",
      "timestamp": "2026-06-03T02:26:00Z"
    }
  ],
  "started_at": "2026-06-03T02:26:00Z",
  "completed_at": "2026-06-03T02:26:30Z"
}
```

### GET `/triage/self-healing/status/{execution_id}`

Get the status of a self-healing execution.

---

## 12. Triage - Escalation

Escalation logic with human-in-the-loop for critical decisions.

### POST `/triage/escalations`

Trigger an escalation for an incident.

**Request:**

```json
{
  "incident_id": "inc-20260603-001",
  "classification_id": "cl-abc123",
  "reason": "p0_incident",
  "tier": 1
}
```

| Field | Type | Description |
|-------|------|-------------|
| `reason` | enum | `p0_incident`, `self_healing_failure`, `low_confidence_classification`, `manual_escalation` |
| `tier` | integer | Escalation tier: 1=engineer, 2=team lead, 3=SRE manager |

**Response `200`:**

```json
{
  "id": "esc-001",
  "incident_id": "inc-20260603-001",
  "tier": 1,
  "status": "paging",
  "paged_users": [
    {
      "user_id": "sre-bob",
      "name": "Bob Smith",
      "role": "Primary On-Call",
      "channel": "pagerduty",
      "acknowledged_at": null
    }
  ],
  "reason": "p0_incident",
  "incident_context": {
    "classification": { ... },
    "rca": { ... },
    "suggested_steps": [
      "1. Review the RCA analysis and confirm root cause",
      "2. Execute the suggested remediation or approve the auto-generated PR",
      "3. Monitor recovery and update the incident timeline"
    ]
  },
  "created_at": "2026-06-03T02:26:00Z"
}
```

### GET `/triage/escalations/{escalation_id}`

Get escalation status including acknowledgement and resolution times.

### GET/PUT `/triage/escalations/policy`

Get or update the escalation policy configuration.

---

## 13. Workspace - Sync

Progressive sync between local workspace and cloud backend.

### POST `/workspace/sync`

Sync local changes to the cloud backend with priority ordering.

**Request:**

```json
{
  "workspace_id": "ws-sre-team-alpha",
  "changes": [
    {
      "type": "incident_update",
      "incident_id": "inc-20260603-001",
      "crdt_ops": [ ... ],
      "timestamp": "2026-06-03T02:20:00Z",
      "priority": 1
    },
    {
      "type": "runbook_update",
      "runbook_id": "rb-database-failover",
      "crdt_ops": [ ... ],
      "timestamp": "2026-06-03T02:21:00Z",
      "priority": 2
    }
  ],
  "last_sync_token": "sync-token-abc123"
}
```

**Sync Priority Order:**

| Priority | Type | Description |
|----------|------|-------------|
| 1 (Highest) | `incident_update` | Incident timeline and status updates |
| 2 | `runbook_update` | Runbook edits and version changes |
| 3 | `config_update` | Workspace and dashboard configuration |
| 4 (Lowest) | `annotation` | User annotations and notes |

**Response `200`:**

```json
{
  "sync_id": "sync-001",
  "status": "completed",
  "changes_accepted": 5,
  "changes_rejected": 0,
  "sync_token": "sync-token-def456",
  "conflicts": []
}
```

### GET `/workspace/sync/status`

Get sync status for a workspace.

**Response:**

```json
{
  "workspace_id": "ws-sre-team-alpha",
  "pending_changes": 3,
  "last_sync": "2026-06-03T02:25:00Z",
  "sync_history": [
    {
      "sync_id": "sync-001",
      "started_at": "2026-06-03T02:25:00Z",
      "completed_at": "2026-06-03T02:25:02Z",
      "changes_count": 5,
      "status": "completed",
      "bytes_transferred": 15200
    }
  ],
  "connectivity": "online"
}
```

### POST `/workspace/sync/pause` & `/workspace/sync/resume`

Pause or resume sync for a workspace.

---

## 14. Workspace - P2P

Peer-to-peer sync between SRE team member workspaces.

### GET `/workspace/p2p/peers`

List all connected P2P peers for a workspace.

**Response:**

```json
{
  "peers": [
    {
      "peer_id": "peer-alice-mbp",
      "peer_name": "Alice's MacBook",
      "connection_state": "connected",
      "connected_at": "2026-06-03T02:00:00Z",
      "last_heartbeat": "2026-06-03T02:25:00Z",
      "capabilities": ["runbook_editor", "dashboard", "incident_viewer"],
      "region": "us-east-1"
    }
  ]
}
```

### POST `/workspace/p2p/signal`

Exchange WebRTC signaling data for P2P connection establishment.

```json
{
  "workspace_id": "ws-sre-team-alpha",
  "peer_id": "peer-alice-mbp",
  "signal_data": {
    "type": "offer",
    "sdp": "..." // WebRTC SDP payload
  }
}
```

### GET `/workspace/p2p/sync-status`

Get P2P sync status per peer.

---

## Error Codes

| Code | HTTP Status | Description |
|------|-------------|-------------|
| `invalid_request` | 400 | Malformed request body or missing required fields |
| `validation_error` | 400 | Schema validation failure (e.g., invalid runbook YAML) |
| `unauthorized` | 401 | Missing or invalid authentication token |
| `forbidden` | 403 | Token lacks required permissions |
| `not_found` | 404 | Requested resource does not exist |
| `conflict` | 409 | Duplicate resource (e.g., remediation PR already exists) |
| `rate_limited` | 429 | Too many requests |
| `internal_error` | 500 | Unexpected server error |
| `provider_unavailable` | 502 | Cloud provider API is unavailable |
| `classification_low_confidence` | 422 | AI classification confidence below threshold |

---

## Rate Limiting

| Tier | Limit | Window |
|------|-------|--------|
| Free | 1000 requests | per hour |
| Team | 10000 requests | per hour |
| Enterprise | 100000 requests | per hour |

Rate limit headers are returned with every response:

```http
X-RateLimit-Limit: 10000
X-RateLimit-Remaining: 9995
X-RateLimit-Reset: 1622700000
```

---

## Webhooks

The platform can emit webhook events for key actions. Configure webhook endpoints via the admin dashboard.

### Event Types

| Event | Description |
|-------|-------------|
| `remediation.pr_created` | A new remediation PR was created |
| `remediation.pr_merged` | A remediation PR was merged |
| `remediation.rolled_back` | A remediation was rolled back |
| `finops.anomaly_detected` | A cost anomaly was detected |
| `finops.recommendation_generated` | New optimization recommendations are ready |
| `triage.incident_classified` | An incident was classified |
| `triage.escalation_triggered` | An escalation was triggered |
| `workspace.sync_completed` | A workspace sync completed |

---

> **See also**: [OpenAPI Specification](openapi.yaml) for machine-readable API documentation.
