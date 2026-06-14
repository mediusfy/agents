# GITOPS-04: Policy-as-Code for Remediation Approval Gates

## Schema Overview

All tables live in the `gitops` schema.

### Core Tables

| Table | Schema | Purpose |
|---|---|---|
| `policy_rules` | `gitops` | Cached YAML policy rules synced from git |
| `policy_evaluations` | `gitops` | Records of each PR evaluation by the policy engine |
| `policy_violations` | `gitops` | Specific violations detected during evaluation |
| `approval_gates` | `gitops` | Approval gate lifecycle tracking for remediation PRs |
| `approval_gate_approvers` | `gitops` | Required approvers assigned to a gate |
| `approval_gate_escalations` | `gitops` | Escalation history for approval gates |
| `policy_rule_sync_log` | `gitops` | Audit log for rule syncs from git |

### ENUM Types

| Type | Values |
|---|---|
| `policy_rule_severity` | `critical`, `high`, `medium`, `low`, `informational` |
| `policy_rule_effect` | `require_approval`, `block`, `warn`, `escalate` |
| `approval_gate_status` | `pending`, `approved`, `blocked`, `escalated`, `expired`, `denied` |
| `policy_evaluation_status` | `running`, `passed`, `failed`, `error` |
| `approver_type` | `user`, `role`, `team`, `group` |
| `environment_name` | `production`, `staging`, `development`, `sandbox` |

### Domain Events

Two event triggers auto-insert into the `outbox_events` table:

1. **`gitops.ApprovalGateStatusChanged`** - Fires when `approval_gates.status` changes
   - Payload includes: gate_id, pr info, previous_status, new_status, timestamps

2. **`policyEngine.PolicyViolationDetected`** - Fires on INSERT to `policy_violations`
   - Payload includes: violation details, rule info, remediation guidance, PR context

### Views

| View | Purpose |
|---|---|
| `gitops.pr_policy_report` | Complete policy report for a PR including gate, violations, and approvers |
| `gitops.active_policy_violations` | All unresolved violations with PR context |
| `gitops.pending_gates_needing_attention` | Gates in `pending` status sorted by longest wait, for auto-escalation monitoring |

### Trigger Magic

- `gitops.track_gate_status_change()` - Auto-updates `previous_status`, `last_status_change_at`, `status_change_count`, and status-specific timestamps (`approved_at`, `blocked_at`, `escalated_at`, `denied_at`)
- All tables have auto-updating `updated_at` via `gitops.update_modified_column()`

## Redis Cache (Policy Engine)

Configuration at `docs/database/redis/GITOPS-04_policy_engine_cache.conf`.

Key patterns:
- `policy:rule:{slug}` - Cached rule details
- `policy:rules:env:{environment}` - Rules matching an environment
- `eval:{vendor}:{repo}:{pr}` - Recent evaluation result (TTL: 5 min)
- `gate:{vendor}:{repo}:{pr}` - Gate status (TTL: 30 min)
- `ratelimit:eval:{client_ip}` - Rate limiting

## Migration Files

| File | Description |
|---|---|
| `GITOPS-04_000_policy_as_code.up.sql` | Up migration (create) |
| `GITOPS-04_000_policy_as_code.down.sql` | Down migration (rollback) |
| `GITOPS-04_000_policy_as_code_seed.sql` | 7 baseline policy rules |

## Dependency Order

1. GITOPS-02_000_schema_setup (creates `gitops` schema and `update_modified_column()` function)
2. GITOPS-04_000_policy_as_code (this migration)
3. Depends on `outbox_events` table existing (from initial schema)
