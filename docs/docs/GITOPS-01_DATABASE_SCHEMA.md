# GITOPS-01: Automated Incident Response via GitOps PRs — Database Schema

## Overview

This schema supports the **Automated Incident Response via GitOps PRs** feature.
When an incident is classified and assigned a runbook, the autonomous triage system
triggers the remediation workflow which auto-creates a GitOps pull request containing
runbook-specified remediation changes.

## Tables

### `gitops_remediation_prs`
Core table tracking GitOps pull requests auto-created from incident remediation triggers.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID PK | Auto-generated primary key |
| incident_id | UUID NOT NULL | FK to incidents (external) |
| pr_number | INTEGER | GitHub/GitLab PR number |
| pr_url | TEXT | URL to the PR |
| pr_title | TEXT | PR title |
| source_branch | TEXT | Remediation branch with changes |
| target_branch | TEXT | Environment-specific branch per policy |
| runbook_reference | TEXT | Reference to the runbook used |
| incident_severity | gitops_severity | Severity level |
| remediation_content_hash | TEXT | SHA256 of remediation content |
| status | gitops_pr_status | Current PR lifecycle status |
| created_at | TIMESTAMPTZ | Row creation timestamp |
| updated_at | TIMESTAMPTZ | Row last-updated timestamp |

### `gitops_ci_checks`
Tracks CI check executions on GitOps remediation PRs.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID PK | Auto-generated primary key |
| pr_id | UUID FK | FK to gitops_remediation_prs |
| check_type | gitops_ci_check_type | Type of CI check |
| status | gitops_ci_check_status | Execution status |
| check_run_id | TEXT | External CI system run ID |
| details | JSONB | Additional metadata |
| started_at | TIMESTAMPTZ | When check started |
| completed_at | TIMESTAMPTZ | When check completed |
| created_at | TIMESTAMPTZ | Row creation timestamp |
| updated_at | TIMESTAMPTZ | Row last-updated timestamp |

### `gitops_pr_events`
Outbox table for GitOps PR events published to downstream dashboards.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID PK | Auto-generated primary key |
| pr_id | UUID FK | FK to gitops_remediation_prs |
| event_type | gitops_event_type | Event type classification |
| payload | JSONB | Event payload |
| status | gitops_event_status | Publication status |
| published_at | TIMESTAMPTZ | When published |
| error_message | TEXT | Error details if failed |
| created_at | TIMESTAMPTZ | Row creation timestamp |
| updated_at | TIMESTAMPTZ | Row last-updated timestamp |

## Enums

- **gitops_severity**: `'critical'`, `'high'`, `'medium'`, `'low'`
- **gitops_pr_status**: `'draft'`, `'pending_checks'`, `'checks_passed'`, `'checks_failed'`, `'merged'`, `'closed'`
- **gitops_ci_check_type**: `'syntax_validation'`, `'policy_as_code'`
- **gitops_ci_check_status**: `'pending'`, `'running'`, `'passed'`, `'failed'`, `'skipped'`
- **gitops_event_type**: `'RemediationPRCreated'`, `'CICheckCompleted'`, `'PullRequestStatusPublished'`
- **gitops_event_status**: `'pending'`, `'published'`, `'failed'`

## Indexes

### gitops_remediation_prs
- `idx_gitops_prs_incident_id` — fast incident lookup
- `idx_gitops_prs_status` — filter by lifecycle status
- `idx_gitops_prs_severity` — filter by severity
- `idx_gitops_prs_incident_status` — composite (incident_id, status)
- `idx_gitops_prs_created_at` — time-range queries

### gitops_ci_checks
- `idx_gitops_checks_pr_id` — FK lookup
- `idx_gitops_checks_status` — filter by check status
- `idx_gitops_checks_pr_type` — composite (pr_id, check_type)
- `idx_gitops_checks_started_at` — time-range queries

### gitops_pr_events
- `idx_gitops_events_status` — outbox polling
- `idx_gitops_events_type` — filter by event type
- `idx_gitops_events_pr_type` — composite (pr_id, event_type)
- `idx_gitops_events_created_at` — time-range queries

## Events

The following events are published via the `gitops_pr_events` outbox:

1. **gitops.RemediationPRCreated** — Published when a remediation PR is auto-created
2. **gitops.CICheckCompleted** — Fired when all CI checks complete
3. **gitops.PullRequestStatusPublished** — Composite PR status for downstream dashboards

## Redis Cache

A dedicated Redis namespace `gitops:pr:*` is used to cache:
- PR status summary (TTL: 5 min)
- CI check aggregated results (TTL: 2 min)
- Active (un-merged) PRs list (TTL: 1 min)
