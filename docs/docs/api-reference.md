# Rufkis SRE Platform API Reference

> **Version:** 1.0.0  
> **Base URL:** `https://api.rufkis.io/api/v1`  
> **Specification:** [OpenAPI 3.1](../openapi.yaml)

---

## Table of Contents

1. [Incidents](#1-incidents)
   - [List Incidents](#11-list-incidents)
   - [Create Incident](#12-create-incident)
   - [Get Incident](#13-get-incident)
   - [Update Incident](#14-update-incident)
   - [List Incident Notes](#15-list-incident-notes)
   - [Create Incident Note](#16-create-incident-note)
   - [Trigger Triage](#17-trigger-triage)
2. [Runbooks](#2-runbooks)
   - [List Runbooks](#21-list-runbooks)
   - [Create Runbook](#22-create-runbook)
   - [Get Runbook](#23-get-runbook)
   - [Update Runbook](#24-update-runbook)
   - [Delete Runbook](#25-delete-runbook)
   - [Execute Runbook](#26-execute-runbook)
   - [Get Execution History](#27-get-execution-history)
3. [Remediations](#3-remediations)
   - [List Remediations](#31-list-remediations)
   - [Create Remediation](#32-create-remediation)
   - [Get Remediation](#33-get-remediation)
   - [Update Remediation](#34-update-remediation)
   - [Delete Remediation](#35-delete-remediation)
   - [Execute Remediation](#36-execute-remediation)
   - [Get Execution History](#37-get-remediation-execution-history)
   - [Rollback Remediation](#38-rollback-remediation)
4. [Policies](#4-policies)
   - [List Policies](#41-list-policies)
   - [Create Policy](#42-create-policy)
   - [Get Policy](#43-get-policy)
   - [Update Policy](#44-update-policy)
   - [Delete Policy](#45-delete-policy)
   - [Validate Policy](#46-validate-policy)
5. [FinOps Costs](#5-finops-costs)
   - [List Costs](#51-list-costs)
   - [Get Cost Entry](#52-get-cost-entry)
   - [Get Cost Summary](#53-get-cost-summary)
6. [FinOps Reports](#6-finops-reports)
   - [List Reports](#61-list-reports)
   - [Generate Report](#62-generate-report)
   - [Get Report](#63-get-report)
   - [Download Report](#64-download-report)
7. [FinOps Savings](#7-finops-savings)
   - [List Savings Recommendations](#71-list-savings-recommendations)
8. [Triage](#8-triage)
   - [List Triage Analyses](#81-list-triage-analyses)
   - [Get Triage Analysis](#82-get-triage-analysis)
   - [Get Triage Recommendations](#83-get-triage-recommendations)
   - [Escalate Triage](#84-escalate-triage)
   - [Resolve Triage](#85-resolve-triage)
9. [Workspace](#9-workspace)
   - [Get Workspace](#91-get-workspace)
   - [Update Workspace](#92-update-workspace)
   - [Get Workspace Status](#93-get-workspace-status)
   - [Trigger Sync](#94-trigger-sync)
   - [List Plugins](#95-list-plugins)
   - [Install Plugin](#96-install-plugin)
   - [Export Workspace](#97-export-workspace)

---

## 1. Incidents

### 1.1 List Incidents

```
GET /incidents
```

Returns a paginated list of incidents with optional filtering.

#### Query Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `status` | string | No | — | Filter by status: `open`, `acknowledged`, `investigating`, `resolved`, `closed` |
| `severity` | string | No | — | Filter by severity: `critical`, `major`, `minor`, `warning`, `info` |
| `assignee_id` | uuid | No | — | Filter by assignee |
| `runbook_id` | uuid | No | — | Filter by associated runbook |
| `created_after` | date-time | No | — | ISO 8601 timestamp filter |
| `created_before` | date-time | No | — | ISO 8601 timestamp filter |
| `search` | string | No | — | Full-text search across title and description |
| `page` | integer | No | 1 | Page number (1-indexed) |
| `page_size` | integer | No | 25 | Items per page (max 100) |

#### Response `200`

```json
{
  "items": [
    {
      "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
      "title": "Elevated error rate in API Gateway",
      "description": "Error rate on api-gateway has exceeded 5% threshold for 10 minutes",
      "status": "open",
      "severity": "critical",
      "source": "prometheus",
      "assignee_id": null,
      "runbook_id": null,
      "remediation_id": null,
      "policy_id": "e5f6a7b8-c9d0-1234-efab-345678901234",
      "triage_id": null,
      "tags": ["networking", "production"],
      "metadata": {
        "region": "us-east-1",
        "service": "api-gateway"
      },
      "created_at": "2026-06-03T01:30:00Z",
      "updated_at": "2026-06-03T02:00:00Z",
      "resolved_at": null,
      "closed_at": null
    }
  ],
  "pagination": {
    "page": 1,
    "page_size": 25,
    "total": 142,
    "total_pages": 6
  }
}
```

---

### 1.2 Create Incident

```
POST /incidents
```

Creates a new incident. The incident is automatically evaluated against active policies.

#### Request Body

```json
{
  "title": "Elevated error rate in API Gateway",
  "description": "Error rate on api-gateway has exceeded 5% threshold for 10 minutes",
  "severity": "critical",
  "source": "prometheus",
  "assignee_id": "b2c3d4e5-f6a7-8901-bcde-f12345678901",
  "tags": ["networking"],
  "metadata": {
    "region": "us-east-1"
  }
}
```

#### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `title` | string | Incident title |
| `severity` | string | One of: `critical`, `major`, `minor`, `warning`, `info` |
| `source` | string | Source system that detected the incident |

#### Response `201`

Returns the created [Incident](#11-list-incidents) object.

---

### 1.3 Get Incident

```
GET /incidents/{incident_id}
```

Returns full incident details including timeline events and associated resources.

#### Path Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `incident_id` | uuid | The unique identifier of the incident |

#### Response `200`

Returns the full [Incident](#11-list-incidents) object.

---

### 1.4 Update Incident

```
PATCH /incidents/{incident_id}
```

Partially updates an incident. Only provided fields are modified.

#### Path Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `incident_id` | uuid | The unique identifier of the incident |

#### Request Body

```json
{
  "status": "acknowledged",
  "assignee_id": "b2c3d4e5-f6a7-8901-bcde-f12345678901"
}
```

#### Response `200`

Returns the updated [Incident](#11-list-incidents) object.

---

### 1.5 List Incident Notes

```
GET /incidents/{incident_id}/notes
```

Returns all notes attached to an incident in chronological order.

#### Response `200`

```json
[
  {
    "id": "note-1",
    "incident_id": "a1b2c3d4-...",
    "author_id": "b2c3d4e5-...",
    "author_name": "Alice SRE",
    "content": "Rolled back api-gateway to v2.1.3. Error rate dropping.",
    "note_type": "manual",
    "created_at": "2026-06-03T01:45:00Z"
  }
]
```

---

### 1.6 Create Incident Note

```
POST /incidents/{incident_id}/notes
```

Appends a new note to the incident's timeline.

#### Request Body

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `content` | string | ✅ | — | Note content |
| `note_type` | string | No | `manual` | `manual`, `automated`, or `system` |

#### Response `201`

Returns the created [IncidentNote](#15-list-incident-notes) object.

---

### 1.7 Trigger Triage

```
POST /incidents/{incident_id}/triage
```

Triggers the autonomous agent triage engine for the specified incident. The agent analyzes the incident and produces recommendations.

#### Path Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `incident_id` | uuid | The incident to triage |

#### Request Body (optional)

```json
{
  "context": {
    "alert_source": "prometheus",
    "raw_alert_data": {
      "metric": "error_rate",
      "value": 8.5,
      "threshold": 5.0
    },
    "additional_notes": "This started after the last deployment"
  }
}
```

#### Response `200` (Synchronous)

Returns the complete [TriageResult](#82-get-triage-analysis).

#### Response `202` (Async)

```json
{
  "triage_id": "f6a7b8c9-d0e1-2345-fabc-456789012345",
  "status": "queued"
}
```

---

## 2. Runbooks

### 2.1 List Runbooks

```
GET /runbooks
```

#### Query Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `status` | string | No | — | `active`, `draft`, `archived` |
| `category` | string | No | — | Filter by category |
| `search` | string | No | — | Full-text search |
| `page` | integer | No | 1 | Page number |
| `page_size` | integer | No | 25 | Items per page (max 100) |

#### Response `200`

```json
{
  "items": [
    {
      "id": "c3d4e5f6-a7b8-9012-cdef-123456789012",
      "name": "API Gateway Recovery",
      "description": "Steps to recover API Gateway from elevated error rates",
      "category": "networking",
      "status": "active",
      "version": "1.2.0",
      "steps": [
        {
          "id": "step-1",
          "name": "Verify API Gateway health",
          "description": "Check /health endpoint and verify 200 response",
          "action": "api_call",
          "api_endpoint": "https://api-gateway.internal/health",
          "api_method": "GET",
          "expected_result": "200 OK",
          "timeout_seconds": 30,
          "on_failure": "notify",
          "approval_required": false
        },
        {
          "id": "step-2",
          "name": "Restart gateway pods",
          "description": "Rolling restart of API Gateway pods",
          "action": "script",
          "command": "kubectl rollout restart deployment/api-gateway -n production",
          "timeout_seconds": 300,
          "on_failure": "stop",
          "approval_required": true
        }
      ],
      "git_source": {
        "repo_url": "https://github.com/rufkis/runbooks",
        "path": "runbooks/api-gateway-recovery.yaml",
        "commit_sha": "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
      },
      "timeout_seconds": 600,
      "tags": ["networking", "api-gateway"],
      "created_at": "2026-01-15T10:00:00Z",
      "updated_at": "2026-05-20T14:30:00Z"
    }
  ],
  "pagination": { "page": 1, "page_size": 25, "total": 12, "total_pages": 1 }
}
```

---

### 2.2 Create Runbook

```
POST /runbooks
```

#### Required Fields

- `name` (string)
- `steps` (array of RunbookStep objects)

Each step requires:
- `id` (string) — Step identifier
- `name` (string) — Step name
- `action` (string) — `manual`, `script`, `api_call`, `webhook`, `approval`, or `notification`

---

### 2.3 Get Runbook

```
GET /runbooks/{runbook_id}
```

Returns the full runbook definition including all steps.

---

### 2.4 Update Runbook

```
PUT /runbooks/{runbook_id}
```

Full replacement of the runbook. All steps must be provided.

---

### 2.5 Delete Runbook

```
DELETE /runbooks/{runbook_id}
```

Returns `204 No Content` on success. Returns `409 Conflict` if the runbook is currently in use.

---

### 2.6 Execute Runbook

```
POST /runbooks/{runbook_id}/execute
```

Triggers immediate execution of a runbook.

#### Request Body

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `incident_id` | uuid | No | Associate with an incident |
| `parameters` | object | No | Runbook-specific input parameters |
| `reason` | string | No | Human-readable reason for execution |

#### Response `200` / `202`

Returns a [RunbookExecution](#27-get-execution-history) object.

---

### 2.7 Get Execution History

```
GET /runbooks/{runbook_id}/history
```

Returns a paginated list of past executions.

#### Query Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `status` | string | No | — | `pending`, `running`, `succeeded`, `failed`, `cancelled` |
| `page` | integer | No | 1 | |
| `page_size` | integer | No | 25 | |

#### Response `200`

```json
{
  "items": [
    {
      "id": "exec-1",
      "runbook_id": "c3d4e5f6-...",
      "incident_id": "a1b2c3d4-...",
      "status": "succeeded",
      "started_at": "2026-06-03T01:35:00Z",
      "completed_at": "2026-06-03T01:38:00Z",
      "triggered_by": "system",
      "current_step": 2,
      "total_steps": 2,
      "step_results": [
        {
          "step_id": "step-1",
          "status": "succeeded",
          "started_at": "2026-06-03T01:35:00Z",
          "completed_at": "2026-06-03T01:35:03Z",
          "output": "200 OK"
        },
        {
          "step_id": "step-2",
          "status": "succeeded",
          "started_at": "2026-06-03T01:35:05Z",
          "completed_at": "2026-06-03T01:36:30Z",
          "output": "deployment.apps/api-gateway restarted"
        }
      ],
      "error": null,
      "created_at": "2026-06-03T01:35:00Z"
    }
  ],
  "pagination": { "page": 1, "page_size": 25, "total": 45, "total_pages": 2 }
}
```

---

## 3. Remediations

### 3.1 List Remediations

```
GET /remediations
```

#### Query Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `status` | string | No | — | `active`, `inactive`, `draft`, `deprecated` |
| `source_repo` | string | No | — | Filter by Git repository URL |
| `page` | integer | No | 1 | |
| `page_size` | integer | No | 25 | |

#### Response `200`

```json
{
  "items": [
    {
      "id": "d4e5f6a7-b8c9-0123-defa-234567890123",
      "name": "Scale Down Unused Compute",
      "description": "Automatically scale down compute instances with < 5% CPU utilization for 7 days",
      "status": "active",
      "source_repo": "https://github.com/rufkis/remediations",
      "source_path": "remediations/scale-down-unused-compute.yaml",
      "source_commit": "b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1",
      "pipeline_type": "kubernetes",
      "parameters_schema": {
        "type": "object",
        "properties": {
          "namespace": { "type": "string" },
          "cpu_threshold": { "type": "number", "default": 5 }
        }
      },
      "auto_approve": false,
      "rollback_enabled": true,
      "timeout_seconds": 900,
      "tags": ["compute", "cost-optimization"],
      "last_execution_id": null,
      "last_execution_status": null,
      "created_at": "2026-02-01T08:00:00Z",
      "updated_at": "2026-05-15T12:00:00Z"
    }
  ],
  "pagination": { "page": 1, "page_size": 25, "total": 8, "total_pages": 1 }
}
```

---

### 3.2 Create Remediation

```
POST /remediations
```

Creates a new GitOps-native remediation. The remediation definition can reference a Git repository as the source of truth.

#### Required Fields

- `name` (string) — Remediation name
- `pipeline_type` (string) — `terraform`, `helm`, `shell`, `kubernetes`, or `custom`

---

### 3.3–3.5 Get / Update / Delete Remediation

Standard CRUD operations on `/remediations/{remediation_id}`.

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/remediations/{id}` | Get remediation details |
| `PUT` | `/remediations/{id}` | Full replacement |
| `DELETE` | `/remediations/{id}` | Permanently delete |

---

### 3.6 Execute Remediation

```
POST /remediations/{remediation_id}/execute?async=false
```

#### Query Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `async` | boolean | No | `false` | Execute asynchronously (returns 202) |

#### Request Body

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `incident_id` | uuid | ✅ | Associate with an incident |
| `parameters` | object | No | Remediation-specific input parameters |
| `commit_sha` | string | No | Pin to a specific Git commit SHA |

#### Response `200`

```json
{
  "id": "exec-1",
  "remediation_id": "d4e5f6a7-...",
  "incident_id": "a1b2c3d4-...",
  "status": "succeeded",
  "commit_sha": "b2c3d4e5...",
  "parameters": { "namespace": "production", "cpu_threshold": 5 },
  "output": "Scaled down deployment api-gateway from 5 to 2 replicas",
  "error": null,
  "started_at": "2026-06-03T01:40:00Z",
  "completed_at": "2026-06-03T01:42:30Z",
  "triggered_by": "policy:auto-remediate-high-error-rates",
  "created_at": "2026-06-03T01:40:00Z"
}
```

---

### 3.7 Get Remediation Execution History

```
GET /remediations/{remediation_id}/history
```

Supports filtering by `status`: `queued`, `running`, `succeeded`, `failed`, `rolled_back`.

---

### 3.8 Rollback Remediation

```
POST /remediations/{remediation_id}/rollback
```

Initiates a rollback of the last successful execution. Rollback logic is defined within the remediation pipeline itself (GitOps-native approach).

#### Request Body

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `execution_id` | uuid | No | Specific execution to rollback (defaults to last) |
| `reason` | string | No | Reason for the rollback |

#### Response `200`

Returns a [RemediationExecution](#36-execute-remediation) with status `rolled_back`.

---

## 4. Policies

### 4.1 List Policies

```
GET /policies
```

#### Query Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `status` | string | No | — | `enabled`, `disabled`, `dry_run` |
| `severity` | string | No | — | Target severity filter |
| `page` | integer | No | 1 | |
| `page_size` | integer | No | 25 | |

#### Response `200`

```json
{
  "items": [
    {
      "id": "e5f6a7b8-c9d0-1234-efab-345678901234",
      "name": "Auto-remediate high error rates",
      "description": "When error rate exceeds 5% for 10 minutes, trigger remediation",
      "status": "enabled",
      "severity": "critical",
      "conditions": {
        "metric": "error_rate",
        "operator": "gt",
        "threshold": 5.0,
        "duration_seconds": 600,
        "match_labels": {
          "service": "api-gateway"
        }
      },
      "actions": [
        {
          "action_type": "remediation",
          "target_id": "d4e5f6a7-...",
          "target_name": "Scale Down Unused Compute",
          "params": {}
        },
        {
          "action_type": "notification",
          "target_name": "on-call-slack",
          "params": {
            "channel": "#on-call-alerts"
          }
        }
      ],
      "cooldown_seconds": 3600,
      "created_at": "2026-03-01T00:00:00Z",
      "updated_at": "2026-05-01T00:00:00Z"
    }
  ],
  "pagination": { "page": 1, "page_size": 25, "total": 15, "total_pages": 1 }
}
```

---

### 4.2 Create Policy

```
POST /policies
```

#### Required Fields

- `name` (string) — Policy name
- `conditions` (object) — with required sub-fields: `metric`, `operator`, `threshold`
- `actions` (array) — each must include `action_type` and `target_id`

#### Condition Operators

| Operator | Description |
|----------|-------------|
| `gt` | Greater than |
| `gte` | Greater than or equal |
| `lt` | Less than |
| `lte` | Less than or equal |
| `eq` | Equal |
| `neq` | Not equal |

#### Action Types

| Type | Description |
|------|-------------|
| `runbook` | Execute a runbook |
| `remediation` | Execute a remediation pipeline |
| `notification` | Send a notification |
| `triage` | Trigger autonomous triage |

---

### 4.3–4.5 Get / Update / Delete Policy

Standard CRUD operations on `/policies/{policy_id}`.

---

### 4.6 Validate Policy (Dry-Run)

```
POST /policies/{policy_id}/validate
```

Validates a policy without enabling it. Optionally accepts a simulation context to test against.

#### Request Body (optional)

```json
{
  "simulation_context": {
    "severity": "critical",
    "source": "prometheus",
    "title": "Test incident for policy validation"
  }
}
```

#### Response `200`

```json
{
  "policy_id": "e5f6a7b8-...",
  "valid": true,
  "matched_conditions": ["error_rate > 5.0 for 600s"],
  "would_trigger_actions": [
    {
      "action_type": "remediation",
      "target_id": "d4e5f6a7-...",
      "target_name": "Scale Down Unused Compute"
    }
  ],
  "errors": []
}
```

---

## 5. FinOps Costs

### 5.1 List Costs

```
GET /finops/costs
```

#### Query Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `provider` | string | No | — | `aws`, `gcp`, `azure`, `other` |
| `service` | string | No | — | Filter by service name |
| `region` | string | No | — | Filter by cloud region |
| `start_date` | date | No | — | ISO 8601 date start |
| `end_date` | date | No | — | ISO 8601 date end |
| `page` | integer | No | 1 | |
| `page_size` | integer | No | 25 | |

#### Response `200`

```json
{
  "items": [
    {
      "id": "cost-1",
      "provider": "aws",
      "service": "EC2",
      "region": "us-east-1",
      "account_id": "123456789012",
      "resource_id": "i-0abcd1234efgh5678",
      "cost_amount": 1234.56,
      "currency": "USD",
      "usage_quantity": 744.0,
      "usage_unit": "hours",
      "cost_category": "compute",
      "date": "2026-06-02",
      "tags": { "environment": "production", "team": "platform" },
      "created_at": "2026-06-03T00:00:00Z"
    }
  ],
  "pagination": { "page": 1, "page_size": 25, "total": 15000, "total_pages": 600 }
}
```

---

### 5.2 Get Cost Entry

```
GET /finops/costs/{cost_id}
```

Returns detailed data for a single cost entry.

---

### 5.3 Get Cost Summary

```
GET /finops/costs/summary
```

#### Query Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `group_by` | string | No | `service` | `provider`, `service`, `region`, `daily`, `monthly` |
| `start_date` | date | No | — | ISO 8601 date start |
| `end_date` | date | No | — | ISO 8601 date end |
| `provider` | string | No | — | Filter by provider |

#### Response `200`

```json
{
  "total_cost": 45231.89,
  "currency": "USD",
  "start_date": "2026-06-01",
  "end_date": "2026-06-30",
  "groups": [
    { "key": "EC2", "cost": 12345.67, "percentage": 27.3, "trend": "stable" },
    { "key": "S3", "cost": 8901.23, "percentage": 19.7, "trend": "increasing" },
    { "key": "RDS", "cost": 6789.01, "percentage": 15.0, "trend": "decreasing" }
  ],
  "provider_breakdown": {
    "aws": 30000.00,
    "gcp": 10000.00,
    "azure": 5231.89
  }
}
```

---

## 6. FinOps Reports

### 6.1 List Reports

```
GET /finops/reports
```

Returns paginated list of generated reports.

#### Query Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `status` | string | No | — | `generating`, `completed`, `failed` |

---

### 6.2 Generate Report

```
POST /finops/reports
```

Initiates asynchronous report generation.

#### Request Body

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `title` | string | ✅ | — | Report title |
| `start_date` | date | ✅ | — | Start date for report data |
| `end_date` | date | ✅ | — | End date for report data |
| `report_type` | string | No | `cost_analysis` | `cost_analysis`, `savings_recommendations`, `roi_analysis`, `budget_comparison`, `custom` |
| `group_by` | string | No | `service` | `provider`, `service`, `region`, `daily`, `monthly` |
| `providers` | array | No | all | `aws`, `gcp`, `azure` |
| `formats` | array | No | `["csv"]` | `csv`, `pdf`, `xlsx` |

#### Response `202`

```json
{
  "report_id": "f6a7b8c9-...",
  "status": "generating"
}
```

---

### 6.3 Get Report

```
GET /finops/reports/{report_id}
```

Returns report details including status and available formats.

---

### 6.4 Download Report

```
GET /finops/reports/{report_id}/download?format=csv
```

Downloads the generated report file.

#### Query Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `format` | string | No | `csv` | `csv`, `pdf`, `xlsx` |

#### Response `200`

Returns the file content with appropriate Content-Type header.

---

## 7. FinOps Savings

### 7.1 List Savings Recommendations

```
GET /finops/savings
```

Returns a paginated list of automated FinOps ROI/savings recommendations.

#### Query Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `status` | string | No | — | `pending`, `applied`, `dismissed`, `in_progress` |
| `category` | string | No | — | `compute_rightsizing`, `reserved_instances`, `storage_optimization`, `data_transfer`, `idle_resources`, `license_optimization` |
| `min_savings` | number | No | — | Minimum estimated monthly savings (USD) |
| `page` | integer | No | 1 | |
| `page_size` | integer | No | 25 | |

#### Response `200`

```json
{
  "items": [
    {
      "id": "savings-1",
      "title": "Rightsize m5.xlarge to m5.large for dev instances",
      "description": "10 EC2 instances in dev have < 10% CPU utilization for the past 30 days",
      "category": "compute_rightsizing",
      "provider": "aws",
      "service": "EC2",
      "region": "us-east-1",
      "resource_id": "i-0abcd1234efgh5678",
      "current_cost_monthly": 500.00,
      "estimated_savings_monthly": 250.00,
      "savings_percentage": 50.0,
      "estimated_annual_savings": 3000.00,
      "confidence_score": 85,
      "implementation_cost": 50.00,
      "roe": 5.0,
      "status": "pending",
      "suggested_actions": [
        "Modify instance type from m5.xlarge to m5.large",
        "Schedule change during maintenance window"
      ],
      "created_at": "2026-06-01T00:00:00Z",
      "updated_at": "2026-06-03T00:00:00Z"
    }
  ],
  "pagination": { "page": 1, "page_size": 25, "total": 42, "total_pages": 2 },
  "total_potential_savings": 12500.00
}
```

#### Key Metrics

| Field | Description |
|-------|-------------|
| `confidence_score` | 0–100: How confident the AI is in this recommendation |
| `roe` | Return on Effort: estimated savings / implementation cost |
| `estimated_annual_savings` | Projected annual savings in USD |
| `savings_percentage` | Percentage reduction in current cost |

---

## 8. Triage

### 8.1 List Triage Analyses

```
GET /triage
```

#### Query Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `status` | string | No | — | `queued`, `processing`, `completed`, `failed` |
| `incident_id` | uuid | No | — | Filter by associated incident |
| `page` | integer | No | 1 | |
| `page_size` | integer | No | 25 | |

---

### 8.2 Get Triage Analysis

```
GET /triage/{triage_id}
```

Returns the full triage analysis result including all recommendations.

#### Response `200`

```json
{
  "id": "f6a7b8c9-d0e1-2345-fabc-456789012345",
  "incident_id": "a1b2c3d4-...",
  "status": "completed",
  "agent_version": "2.1.0",
  "analysis_duration_ms": 2340,
  "recommendations": [
    {
      "type": "runbook_execution",
      "priority": 1,
      "title": "Execute API Gateway Recovery Runbook",
      "description": "Based on the error patterns, executing the API Gateway Recovery runbook should mitigate the issue.",
      "confidence": 92,
      "target_id": "c3d4e5f6-...",
      "target_name": "API Gateway Recovery",
      "rationale": "Incident symptoms match 3 previous incidents that were resolved by this runbook.",
      "automated": false
    },
    {
      "type": "severity_change",
      "priority": 2,
      "title": "Adjust severity to major",
      "description": "The incident affects production but has a known workaround.",
      "confidence": 78,
      "rationale": "Historical incidents with similar error rates were classified as major.",
      "automated": true
    }
  ],
  "suggested_severity": "major",
  "suggested_assignee_id": "b2c3d4e5-...",
  "suggested_runbook_id": "c3d4e5f6-...",
  "suggested_remediation_id": null,
  "confidence_score": 87,
  "summary": "This appears to be a networking-related incident affecting the API Gateway in us-east-1. Similar to incident INC-2024-05-31-001 which was resolved by scaling out the gateway instances.",
  "error": null,
  "escalation_id": null,
  "created_at": "2026-06-03T01:35:00Z",
  "completed_at": "2026-06-03T01:35:03Z"
}
```

---

### 8.3 Get Triage Recommendations

```
GET /triage/{triage_id}/recommendations
```

Returns only the recommendations array from the triage analysis.

---

### 8.4 Escalate Triage

```
POST /triage/{triage_id}/escalate
```

Escalates a triage analysis to a human operator or on-call team.

#### Request Body

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `escalation_reason` | string | No | — | Reason for escalation |
| `target_team` | string | No | — | Target team or on-call schedule |
| `priority` | string | No | `normal` | `low`, `normal`, `high`, `urgent` |

#### Response `200`

```json
{
  "escalation_id": "esc-1",
  "triage_id": "f6a7b8c9-...",
  "status": "pending"
}
```

---

### 8.5 Resolve Triage

```
POST /triage/{triage_id}/resolve
```

Marks a triage analysis as resolved with optional agent feedback.

#### Request Body

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `resolution_notes` | string | No | Notes about the resolution |
| `agent_feedback.accuracy_score` | integer (1–5) | No | Rating of recommendation accuracy |
| `agent_feedback.actionable` | boolean | No | Whether recommendations were actionable |
| `agent_feedback.comments` | string | No | Free-text feedback |

#### Response `200`

Returns the updated [TriageResult](#82-get-triage-analysis).

---

## 9. Workspace

### 9.1 Get Workspace

```
GET /workspace
```

Returns the local-first SRE workspace configuration.

#### Response `200`

```json
{
  "id": "ws-1",
  "name": "Production SRE Workspace",
  "description": "Primary SRE workspace for production environments",
  "version": "1.0.0",
  "settings": {
    "offline_mode": true,
    "sync_interval_seconds": 300,
    "auto_sync": true,
    "default_runbook_id": null,
    "timezone": "UTC",
    "notification_preferences": {
      "email": true,
      "slack": true,
      "pagerduty": true,
      "webhook_url": null
    }
  },
  "plugins": [
    {
      "id": "plugin-1",
      "name": "grafana-datasource",
      "display_name": "Grafana Datasource",
      "description": "Integrates Grafana dashboards into the workspace",
      "version": "1.2.3",
      "source": "https://plugins.rufkis.io/grafana-datasource",
      "enabled": true,
      "config": {
        "grafana_url": "https://grafana.internal.example.com",
        "api_key_name": "grafana_api_key"
      },
      "permissions": ["read:metrics", "read:alerts"],
      "installed_at": "2026-01-10T12:00:00Z",
      "updated_at": "2026-04-15T10:00:00Z"
    }
  ],
  "last_sync_at": "2026-06-03T02:00:00Z",
  "last_sync_status": "synced",
  "created_at": "2026-01-01T00:00:00Z",
  "updated_at": "2026-06-03T02:00:00Z"
}
```

---

### 9.2 Update Workspace

```
PATCH /workspace
```

Partially updates workspace configuration. Supports local-first settings such as offline mode, sync intervals, and plugin preferences.

---

### 9.3 Get Workspace Status

```
GET /workspace/status
```

Returns sync status, connectivity state, and health metrics.

#### Response `200`

```json
{
  "workspace_id": "ws-1",
  "name": "Production SRE Workspace",
  "connectivity": "online",
  "sync_status": "synced",
  "last_sync_at": "2026-06-03T02:00:00Z",
  "last_sync_duration_ms": 1234,
  "pending_changes": 0,
  "offline_data_size_bytes": 52428800,
  "plugin_count": 5,
  "api_version": "1.0.0",
  "uptime_seconds": 86400,
  "healthy": true
}
```

#### Connectivity States

| State | Description |
|-------|-------------|
| `online` | Connected to the platform |
| `offline` | Working in local-first mode |
| `degraded` | Connected but experiencing issues |

---

### 9.4 Trigger Sync

```
POST /workspace/sync
```

Manually triggers synchronization with the central platform.

#### Request Body

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `full_sync` | boolean | No | `false` | Perform full resync instead of incremental |

#### Response `200`

```json
{
  "sync_id": "sync-1",
  "status": "synced",
  "started_at": "2026-06-03T02:05:00Z",
  "completed_at": "2026-06-03T02:05:03Z",
  "duration_ms": 2850,
  "changes_pulled": 15,
  "changes_pushed": 3,
  "errors": []
}
```

#### Response `202` (Async)

```json
{
  "sync_id": "sync-1",
  "status": "syncing"
}
```

---

### 9.5 List Plugins

```
GET /workspace/plugins
```

Returns all installed workspace plugins.

---

### 9.6 Install Plugin

```
POST /workspace/plugins
```

Installs a new plugin from the registry.

#### Request Body

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `plugin_name` | string | ✅ | Plugin name |
| `source` | string | ✅ | Registry URL or local path |
| `version` | string | No | Specific version (semver) |
| `config` | object | No | Plugin-specific configuration |

#### Response `201`

Returns the installed [WorkspacePlugin](#91-get-workspace).

---

### 9.7 Export Workspace

```
POST /workspace/export
```

Exports workspace configuration as a downloadable JSON or YAML archive.

#### Request Body

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `include_plugins` | boolean | No | `true` | Include plugin configurations |
| `include_history` | boolean | No | `false` | Include execution and sync history |
| `format` | string | No | `json` | `json` or `yaml` |

#### Response `200`

Returns the workspace export payload with appropriate Content-Type.

---

## Common Schemas

### ErrorResponse

```json
{
  "error": "validation_error",
  "message": "The request body failed validation.",
  "code": "ERR_VALIDATION",
  "details": [
    {
      "field": "severity",
      "reason": "must be one of: critical, major, minor, warning, info",
      "value": "extreme"
    }
  ],
  "request_id": "req-a1b2c3d4-..."
}
```

### PaginationInfo

```json
{
  "page": 1,
  "page_size": 25,
  "total": 142,
  "total_pages": 6
}
```

---

## Changelog

### v1.0.0 (2026-06-03)

- Initial release of the Rufkis SRE Platform API
- Incidents, Runbooks, Remediations, Policies, FinOps, Triage, and Workspace endpoints
- OpenAPI 3.1 specification
- Comprehensive error handling and pagination

---

*For additional support, visit [docs.rufkis.io](https://docs.rufkis.io) or contact the SRE Platform Team at sre-platform@rufkis.io.*
