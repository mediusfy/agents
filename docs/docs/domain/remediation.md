# Domain: GitOps-Native Remediation via PRs (RUFKIS-05)

## Bounded Context: Remediation

The **Remediation** bounded context is responsible for automatically creating pull requests against GitOps repositories to remediate infrastructure issues. It integrates with monitoring/anomaly detection systems to trigger fixes, and manages the full lifecycle of remediation PRs.

## Domain Model

### Aggregate Root: Remediation

**Remediation** - A single automated fix that creates a PR against a GitOps repository.

| Field | Type | Description |
|-------|------|-------------|
| id | UUID | Primary identifier |
| target_repo | TEXT | GitOps repository URL |
| branch | TEXT | Target branch (e.g., main, production) |
| source_branch | TEXT | Auto-generated branch name (prefixed with `remediation/`) |
| title | TEXT | PR title |
| description | TEXT | PR description/body (Markdown) |
| changes | JSONB[] | Array of file change objects: {path, content, action} |
| status | ENUM | pending → open → merged/closed/failed |
| pr_url | TEXT | URL to PR on Git provider |
| pr_number | INTEGER | PR number on provider |
| error_message | TEXT | Error details if failed |

### Entity: RemediationPolicy

**RemediationPolicy** - A rule that defines what triggers a remediation and how it should be executed.

| Field | Type | Description |
|-------|------|-------------|
| id | UUID | Primary identifier |
| name | TEXT | Human-readable policy name |
| trigger_type | ENUM | anomaly, drift, security_scan, manual, scheduled |
| target_repo | TEXT | Which repo to target |
| template | JSONB | Template for auto-generating changes |
| auto_approve | BOOLEAN | Whether to auto-approve PRs |
| enabled | BOOLEAN | Whether this policy is active |

### Value Object: FileChange

**FileChange** - A single file modification in a remediation.

| Field | Type | Description |
|-------|------|-------------|
| path | TEXT | File path relative to repo root |
| content | TEXT | New file content |
| action | ENUM | add, modify, delete |

### Value Object: AuditEntry

**AuditEntry** - An immutable log entry for a remediation action.

| Field | Type | Description |
|-------|------|-------------|
| action | ENUM | created, branch_created, changes_applied, pr_created, pr_merged, pr_closed, failed |
| actor | TEXT | Who/what performed the action |
| metadata | JSONB | Additional context |

## State Machine

```
                    ┌─────────┐
                    │ pending │
                    └────┬────┘
                         │ PR created
                    ┌────▼────┐
                    │  open   │
                    └┬───┬───┬┘
                     │   │   │
        PR merged    │   │   │ PR closed
                     │   │   │
              ┌──────▼┐  │  ┌▼───────┐
              │ merged│  │  │ closed │
              └───────┘  │  └────────┘
                         │ error
                    ┌────▼────┐
                    │ failed  │
                    └─────────┘
```

## Domain Events

1. **RemediationCreated** - A new remediation request has been recorded
2. **BranchCreated** - Source branch has been created in the GitOps repo
3. **ChangesApplied** - File changes have been committed to the branch
4. **PRCreated** - Pull request has been opened on the Git provider
5. **PRMerged** - External PR has been merged (synced)
6. **PRClosed** - External PR has been closed (synced)
7. **RemediationFailed** - Remediation hit an error
8. **SyncRequested** - Manual sync of PR state triggered

## Business Rules

1. Source branches MUST be prefixed with `remediation/`
2. Max 10 concurrent PR creations per provider
3. Changes paths MUST NOT contain path traversal sequences
4. Source branch names MUST be unique per repo
5. Status transitions follow the defined state machine
6. Credentials are never returned in API responses (only hints)
