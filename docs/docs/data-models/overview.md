# Rufkis SRE Platform — Data Model Design Document

> **Last updated:** 2026-06-03
> **Status:** Draft v1.0

---

## 1. Overview

The Rufkis SRE Platform is composed of **four interrelated domains**.
Below is the entity-relationship diagram (textual), the complete list of JSON Schema files,
and cross-domain relationship notes.

---

## 2. Master Entity-Relationship Map

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    DOMAIN 4: Local-First Workspace                      │
│                                                                         │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐          │
│  │  User    │◄───│  Device  │    │  CRDT    │    │  P2P     │          │
│  │          │    │          │    │  Item    │    │  Sync    │          │
│  └────┬─────┘    └──────────┘    └──────────┘    └──────────┘          │
│       │                                                                │
│       │  ┌──────────┐    ┌───────────────────┐                         │
│       ├──│  Team    │    │  Workspace        │                         │
│       │  │Membership│    │  StateSnapshot    │                         │
│       │  └────┬─────┘    └───────────────────┘                         │
│       │       │                                                         │
│       │  ┌────▼─────┐    ┌───────────────────┐                         │
│       └──│  Team    │    │  Workspace         │                         │
│          └──────────┘    └─────────┬─────────┘                         │
└────────────────────────────────────┼───────────────────────────────────┘
                                     │
        ┌────────────────────────────┼──────────────────────────────┐
        │                            │                              │
        ▼                            ▼                              ▼
┌──────────────────┐   ┌─────────────────────┐   ┌──────────────────────┐
│  DOMAIN 1:       │   │  DOMAIN 2:          │   │  DOMAIN 3:           │
│  GitOps          │   │  FinOps             │   │  Autonomous Triage   │
│  Remediation     │   │                     │   │                      │
│                  │   │                     │   │                      │
│  ┌─────────┐     │   │  ┌─────────────┐    │   │  ┌──────────┐       │
│  │Runbook  │     │   │  │CostAnomaly  │    │   │  │Incident  │       │
│  │Def.     │     │   │  └──────┬──────┘    │   │  └────┬─────┘       │
│  └────┬────┘     │   │         │           │   │       │             │
│       │          │   │  ┌──────▼──────┐    │   │  ┌────▼─────┐       │
│  ┌────▼────┐     │   │  │Optimization │    │   │  │RCA       │       │
│  │Remed.   │     │   │  │Recommend.   │    │   │  │Summary   │       │
│  │Request  │     │   │  └──────┬──────┘    │   │  └──────────┘       │
│  └────┬────┘     │   │         │           │   │                      │
│       │          │   │  ┌──────▼──────┐    │   │  ┌──────────┐       │
│  ┌────▼────┐     │   │  │ShowbackAlloc│    │   │  │SelfHeal  │       │
│  │Runbook  │     │   │  └─────────────┘    │   │  │Execution │       │
│  │Exec.    │     │   │                     │   │  └──────────┘       │
│  └─────────┘     │   │  ┌─────────────┐    │   │                      │
│                  │   │  │CostVsRel.   │    │   │  ┌──────────┐       │
│  ┌─────────┐     │   │  │Score        │    │   │  │Escalation│       │
│  │Approval │     │   │  └─────────────┘    │   │  │Policy    │       │
│  │Gate     │     │   │                     │   │  └──────────┘       │
│  └─────────┘     │   │                     │   │                      │
│                  │   │                     │   │  ┌──────────┐       │
│  ┌─────────┐     │   │                     │   │  │Timeline  │       │
│  │AuditLog │     │   │                     │   │  │Event     │       │
│  └─────────┘     │   │                     │   │  └──────────┘       │
└──────────────────┘   └─────────────────────┘   └──────────────────────┘
```

---

## 3. File Inventory

| File | Description |
|---|---|
| `openapi/components/schemas/domain1_gitops_remediation.json` | Domain 1: RunbookDefinition, RemediationRequest, ApprovalGate, PolicyRule, AuditLogEntry, RunbookExecution, StepResult, EnvironmentRef |
| `openapi/components/schemas/domain2_finops.json` | Domain 2: CostAnomaly, OptimizationRecommendation, ShowbackAllocation, CostVsReliabilityScore, FinOpsDashboardSummary |
| `openapi/components/schemas/domain3_triage.json` | Domain 3: Incident, IncidentClassification, RCASummary, SelfHealingExecution, EscalationPolicy, EscalationTier, IncidentTimelineEvent |
| `openapi/components/schemas/domain4_workspace.json` | Domain 4: Workspace, WorkspaceSettings, Team, TeamMembership, CRDTItem, CRDTMergeOperation, P2PSyncPayload, WorkspaceStateSnapshot, Device, User |

---

## 4. Cross-Domain Relationship Matrix

| Source Entity | Target Entity | Relationship Type | Semantics |
|---|---|---|---|
| **Incident** (D3) | **Workspace** (D4) | FK `workspace_id` | Every incident belongs to a workspace |
| **Incident** (D3) | **Team** (D4) | FK via `assigned_to` → team_id | Triaged to a team |
| **Incident** (D3) | **EscalationPolicy** (D3) | FK `escalation_policy_id` | Escalation rules apply per incident |
| **Incident** (D3) | **RunbookExecution** (D1) | FK `remediation_execution_id` | Auto-remediated incidents link to execution |
| **SelfHealingExecution** (D3) | **Incident** (D3) | FK `incident_id` | Healing actions tied to incident |
| **SelfHealingExecution** (D3) | **RunbookExecution** (D1) | FK `runbook_execution_id` | Some healing runs a full runbook |
| **RemediationRequest** (D1) | **RunbookDefinition** (D1) | FK `runbook_id` | Request references a runbook |
| **RemediationRequest** (D1) | **ApprovalGate** (D1) | FK `approval_gate_id` | Request is gated by a policy |
| **RemediationRequest** (D1) | **RunbookExecution** (D1) | FK `execution_log_id` | Links request to execution result |
| **RunbookExecution** (D1) | **RunbookDefinition** (D1) | FK `runbook_id` | Execution references the definition |
| **CostAnomaly** (D2) | **OptimizationRecommendation** (D2) | FK via `[]recommendation_ids` | Anomalies link to recommendations |
| **OptimizationRecommendation** (D2) | **RemediationRequest** (D1) | FK `implemented_by_remediation_id` | FinOps recs can be executed via GitOps |
| **CostVsReliabilityScore** (D2) | **Service** (cross) | FK `service_id` | Trade-off scores per service |
| **ShowbackAllocation** (D2) | **Team** (D4) | FK `team_id` | Cost attributed to teams |
| **CRDTItem** (D4) | **Workspace** (D4) | via `data` field | All mutable entities are CRDT items |
| **P2PSyncPayload** (D4) | **Device** (D4) | FK `sender_id` | Sync sent from a device |
| **WorkspaceStateSnapshot** (D4) | **Workspace** (D4) | FK `workspace_id` | Snapshot of workspace state |
| **TeamMembership** (D4) | **Team** (D4) | FK `team_id` | User belongs to team |
| **TeamMembership** (D4) | **User** (D4) | FK `user_id` | User's membership in a team |
| **AuditLogEntry** (D1) | All entities | FK `resource_id` (generic) | Immutable audit trail for all domains |
| **ApprovalGate** (D1) | **Workspace** (D4) | via workspace scope | Policy rules scoped to workspace |
| **User** (D4) | All entities | FK `created_by` / `assigned_to` | Users act across all domains |

---

## 5. Index Strategy Notes

| Table | Recommended Indexes |
|---|---|
| `runbook_definitions` | `(status)`, `(git_repo, git_path)` unique, `(created_by)`, `(created_at)` |
| `remediation_requests` | `(runbook_id)`, `(status)`, `(environment->>'cluster')`, `(requested_by)`, `(created_at)` |
| `audit_log_entries` | `(resource_type, resource_id)`, `(actor_id)`, `(action, timestamp)`, `(correlation_id)` |
| `runbook_executions` | `(runbook_id)`, `(status)`, `(started_at)` |
| `cost_anomalies` | `(region, provider)`, `(severity, status)`, `(detected_at)`, `(team_id)` |
| `optimization_recommendations` | `(status)`, `(provider, region)`, `(roi_months)` |
| `showback_allocations` | `(team_id, billing_period)`, `(service_id)` |
| `cost_vs_reliability_scores` | `(service_id, score_date)`, `(environment->>'cluster')` |
| `incidents` | `(workspace_id, status)`, `(severity, status)`, `(service_id)`, `(detected_at)`, `(assigned_to)` |
| `self_healing_executions` | `(incident_id)`, `(status)`, `(started_at)` |
| `escalation_policies` | `(workspace_id)`, `(is_active)` |
| `incident_timeline_events` | `(incident_id, timestamp)` |
| `workspaces` | `(slug)` unique |
| `teams` | `(workspace_id)`, `(slug)` unique within workspace |
| `team_memberships` | `(team_id, user_id)` unique, `(user_id)` |
| `devices` | `(user_id)`, `(last_seen_at)` |
| `crdt_items` | `(workspace_id, type)`, `(parent_id)`, `(lamport_timestamp)` |
| `p2p_sync_payloads` | `(sender_id, sent_at)`, `(sync_id)` unique |
| `workspace_state_snapshots` | `(workspace_id, version)` |

---

## 6. JSON Schema Files

All schemas are written in **JSON Schema Draft 2020-12** format and are
ready for inclusion in an OpenAPI 3.1.x `components/schemas` section.

Location: `openapi/components/schemas/`
