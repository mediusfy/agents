# Rufkis SRE Platform — Bounded Contexts & Ubiquitous Language

## Overview

This document defines the bounded contexts for the Rufkis SRE Platform, their
ubiquitous language, and integration patterns between them, including
multi-cloud/data-residency constraints.

---

## 1. Context Map

```
┌──────────────────────┐     ┌──────────────────────┐     ┌──────────────────────┐
│                      │     │                      │     │                      │
│    Incident Triage   │◄────│   GitOps Remediation  │────►│   Policy Engine      │
│    (Autonomous       │     │   (Declarative Ops)   │     │   (Policy-as-Code)   │
│     Agent Triage)    │     │                      │     │                      │
└────────┬─────────────┘     └──────────┬───────────┘     └──────────────────────┘
         │                             │                             │
         │  Customer-Supplier          │  Shared Kernel             │  ACL
         ▼                             ▼                             ▼
┌──────────────────────┐     ┌──────────────────────┐     ┌──────────────────────┐
│                      │     │                      │     │                      │
│   FinOps Engine      │────►│   SRE Local-First    │────►│   Cloud Providers    │
│   (Cost Mgmt/ROI)    │     │   Workspace & Sync   │     │   (AWS/GCP/Azure)    │
│                      │     │                      │     │                      │
└──────────────────────┘     └──────────────────────┘     └──────────────────────┘
```

---

## 2. Bounded Context: Incident Triage

**Domain**: Autonomous agent-based incident classification, RCA, self-healing, and escalation.

**Ubiquitous Language**:
| Term | Definition |
|------|------------|
| Incident | An alert or notification from any monitoring source that requires attention |
| Triage Agent | AI-powered agent that classifies severity (P0-P4) and assigns ownership |
| Confidence Score | Float [0.0–1.0] indicating the agent's certainty in its classification |
| RCA Suggestion | Ranked list of likely root causes with supporting evidence |
| Self-Healing Runbook | An automatable runbook that can be executed autonomously |
| Escalation Path | Ordered sequence of on-call tiers to page |
| Human-in-the-Loop | Required human approval gate for P0 incidents or low-confidence classifications |
| Continuous Learning Loop | Feedback mechanism where human corrections improve the triage model |

**Integration Patterns**:
- **Customer-Supplier** to GitOps Remediation (triage triggers remediation PRs)
- **Event-Driven** to FinOps (incidents may trigger cost anomaly correlation)
- **Shared Kernel** with Policy Engine (escalation policies are shared)

**Multi-Cloud Constraint**: RCA for EU incidents must only query EU-region data sources (logs, metrics, traces).

---

## 3. Bounded Context: GitOps Remediation

**Domain**: Declarative infrastructure management via Git pull requests for all remediation actions.

**Ubiquitous Language**:
| Term | Meaning |
|------|---------|
| Remediation PR | Auto-generated pull request containing runbook-specified infrastructure changes |
| Declarative Runbook | YAML definition stored in git with triggers, steps, rollback, and approval requirements |
| Runbook Registry | API to discover, list, and retrieve runbook definitions |
| Audit Trail | Complete git history showing who approved what, when, and rollback hash |
| Approval Gate | Policy-as-code rules that block merges until conditions are met |
| One-Click Revert | Auto-generated revert PR for any merged remediation |
| Configuration Drift | State where actual infrastructure deviates from git-declared desired state |

**Integration Patterns**:
- **Shared Kernel** with Policy Engine (both operate on PR lifecycle)
- **Anti-Corruption Layer** to Cloud Providers (cloud-agnostic runbook definitions)
- **Event Publisher** to Incident Triage (remediation PR status)

**Multi-Cloud Constraint**: Runbook definitions must be cloud-agnostic — a single runbook can target AWS, GCP, Azure, or on-prem.

---

## 4. Bounded Context: FinOps Engine

**Domain**: Cloud cost management, anomaly detection, optimization ROI, and showback/chargeback.

**Ubiquitous Language**:
| Term | Meaning |
|------|---------|
| Cost Anomaly | A cost metric deviating >3σ from trailing 7-day baseline |
| Optimization Recommendation | Resource-specific suggestion with projected savings and ROI score |
| ROI Score | Composite metric (projected savings / implementation complexity) |
| Showback Report | Cost visibility per SRE team without financial transfer |
| Show-Charge Report | Internal chargeback with financial transfer between teams |
| Data Residency Zone | Geographic partition (EU, US) — cost data never crosses zone boundaries |
| Cost vs. Reliability Trade-off | Visualization comparing monthly cost (x-axis) vs SLO attainment (y-axis) |

**Integration Patterns**:
- **Customer-Supplier** to GitOps Remediation (optimization recommendations generate PR templates)
- **Event Listening** from Incident Triage (correlate incidents with cost anomalies)

**Multi-Cloud Constraint**: EU cost data stored exclusively in EU databases; US data in US databases. Cross-region sync is eventual (max 5 min lag). Recommendations must never suggest moving data across residency zones.

---

## 5. Bounded Context: SRE Local-First Workspace

**Domain**: Offline-capable workspace with P2P sync and progressive cloud sync.

**Ubiquitous Language**:
| Term | Meaning |
|------|---------|
| Local-First Architecture | Dashboard operates fully offline using local store (IndexedDB/SQLite); cloud is sync layer, not primary |
| CRDT | Conflict-free Replicated Data Type — allows concurrent edits without conflicts |
| P2P Sync | Direct workspace synchronization between SRE team members in the same region |
| Progressive Sync | Priority-ordered sync to cloud: incident timeline → runbook edits → dashboard state |
| Workspace Session | Shared context where multiple SRE engineers collaborate on an incident |
| Sync Conflict | Cloud version diverged from local CRDT — requires manual resolution |
| CRDT Log Compaction | Garbage collection of local CRDT operation log after successful cloud sync |

**Integration Patterns**:
- **Event Listening** from all other contexts (incident events, cost anomalies, PR status)
- **P2P Layer** operates within data residency zones only (EU↔EU, US↔US)
- **Progressive Sync** uses a customer-supplier relationship with cloud backend

**Multi-Cloud Constraint**: P2P sync is BLOCKED across data residency zones. EU engineers see only EU-authorized data locally. Sync endpoints are region-specific.

---

## 6. Bounded Context: Policy Engine

**Domain**: Policy-as-code evaluation for remediation approval gates.

**Ubiquitous Language**:
| Term | Meaning |
|------|---------|
| Policy Rule | Declarative condition stored in git alongside runbooks |
| Policy Violation | A PR that fails one or more policy rules |
| Required Approver | Identity/role that must approve a PR before merge |
| CAB Approval | Change Advisory Board approval required for production changes |
| Merge Block | Policy condition that prevents PR merge until resolved |

**Integration Patterns**:
- **Shared Kernel** with GitOps Remediation (both reference PR lifecycle and runbook repo)
- **Anti-Corruption Layer** to external compliance systems

---

## 7. Event Catalog Summary

| Event | Owner Context | Key Consumers |
|-------|---------------|---------------|
| `incidentTriage.IncidentClassified` | Incident Triage | GitOps, FinOps, Workspace |
| `triage.RCASuggestionsGenerated` | Incident Triage | Workspace, Continuous Learning |
| `selfHealing.RemediationTriggered` | Incident Triage | GitOps, Incident Management |
| `triage.EscalationTriggered` | Incident Triage | Notification, Audit |
| `gitops.RemediationPRCreated` | GitOps | Policy Engine, Workspace, Dashboard |
| `gitops.RunbookCommitted` | GitOps | Runbook Registry, Workspace |
| `gitops.ApprovalGateStatusChanged` | Policy Engine | GitOps, Notification, Audit |
| `gitops.RemediationRolledBack` | GitOps | Audit, Workspace |
| `finops.CostAnomalyDetected` | FinOps | SRE Dashboard, Notification |
| `finops.OptimizationRecommendationGenerated` | FinOps | GitOps, Dashboard |
| `finops.ShowbackReportGenerated` | FinOps | SRE Teams, Finance |
| `finops.TradeOffDashboardRefreshed` | FinOps | Workspace, Dashboard |
| `workspace.DashboardSyncStatusChanged` | Workspace | UI State, Sync Engine |
| `workspace.RunbookLocallyModified` | Workspace | P2P Sync, Cloud Sync |
| `workspace.P2PSyncCompleted` | Workspace | Workspace Sessions |
| `workspace.ProgressiveSyncCompleted` | Workspace | CRDT Compaction |
