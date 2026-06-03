# Rufkis Kubernetes Console — Bounded Contexts

> **Generated from:** `STRATEGY-2026-05-31.md` analysis  
> **Date:** 2026-05-31  
> **Source:** `docs/STRATEGY-USER-STORIES.md`

---

## 1. Incident Management — Supporting Subdomain

### Ubiquitous Language

| Term | Definition |
|------|-----------|
| **Incident** | A tracked operational event (alert, anomaly, or page) with severity, lifecycle, and associated remediation actions. |
| **Triage Summary** | Pre-populated root-cause analysis placed in the incident tracker by a watcher agent before the SRE is paged. |
| **Remediation Linkage** | The relationship between an incident and the PR(s) generated to fix it. |
| **Time-to-First-Action** | Metric: time from incident creation to first automated or human action. |
| **Time-to-Remediation** | Metric: time from incident creation to PR merge + Argo CD sync. |

### Responsibilities

- Open, update, resolve, and close incidents
- Accept pre-populated triage summaries from watcher agents (AAA-01, AAA-03)
- Link generated PRs back to originating incidents (GOR-05)
- Track time-to-first-action and time-to-remediation metrics
- Support manual incident creation from AI diagnostics
- Provide incident query API for dashboards and reporting

### Domain Events

| Event | Trigger | Description |
|-------|---------|-------------|
| `IncidentManagement.IncidentOpened` | Alert ingested or anomaly detected | Incident record created with severity, source, timestamp |
| `IncidentManagement.IncidentUpdated` | Triage summary posted, PR linked, status changed | Any field change on an open incident |
| `IncidentManagement.IncidentResolved` | PR merged + Argo CD sync completed | Incident closed with resolution note |
| `IncidentManagement.RemediationLinked` | PR submitted referencing an incident | A GitOps PR is linked to the incident |
| `IncidentManagement.TriageSummaryPosted` | Watcher agent completes analysis | Structured triage summary placed in incident before page |

### Integration

- **Consumes from:** Monitoring (Anomstack alerts, anomaly events), My Agents (triage findings)
- **Publishes to:** SRE notification channel (PagerDuty/opsgenie integration), Remediation (to link PRs)
- **Pattern:** Event-driven; no synchronous RPCs

---

## 2. FinOps Policy — Supporting Subdomain

### Ubiquitous Language

| Term | Definition |
|------|-----------|
| **Waste** | Provisioned but unused or over-requested resources (CPU, memory, storage). |
| **Savings Projection** | Estimated monthly/quarterly cost reduction from a right-sizing recommendation. |
| **Right-Sizing Recommendation** | A specific, actionable resource adjustment with computed savings. |
| **Guardrail** | Safety policy: max reduction %, excluded namespaces, minimum observation period, approval required. |
| **Auto-Action Policy** | Policy that determines whether a recommendation auto-generates a PR or requires human approval. |
| **Savings Report** | Periodic (monthly) report of actual cost reduction vs. projected savings. |
| **Cost Baseline** | Historical cost snapshot used to compute projected and actual savings. |

### Responsibilities

- Evaluate waste data from Waste Heatmap against auto-action policies
- Determine whether a recommendation requires human PR or auto-PR
- Enforce guardrails (max reduction %, excluded namespaces, minimum observation period)
- Track actual savings vs. projected savings post-remediation
- Generate periodic savings reports for Finance

### Domain Events

| Event | Trigger | Description |
|-------|---------|-------------|
| `FinOpsPolicy.RecommendationPromoted` | Waste identified and policy evaluated | A recommendation is surfaced or auto-PR'd |
| `FinOpsPolicy.PolicyViolated` | Recommendation exceeds guardrails | Recommendation blocked or escalated |
| `FinOpsPolicy.ScheduledPRTriggered` | Auto-action policy triggers PR | Automated right-sizing PR generated |
| `FinOpsPolicy.SavingsReportGenerated` | Periodic report run | Monthly savings analysis available |

### Integration

- **Consumes from:** Waste Heatmap (waste detection, utilization metrics), Cost Explorer (cost data, projections)
- **Publishes to:** Remediation (PR pipeline via GitOps contract), UI (recommendation cards)
- **Pattern:** Event-driven + policy evaluation interceptor

---

## 3. Agent Governance — Supporting Subdomain

### Ubiquitous Language

| Term | Definition |
|------|-----------|
| **Agent Type** | Classification of autonomous agent (watcher, remediation, diagnostic, etc.) |
| **MCP Tool Access Policy** | Defines which MCP tools an agent type may call, with what scope (read/write, namespace filter) |
| **Resource Quota** | CPU/memory limits per agent or agent type |
| **Agent Audit Log** | Immutable, ordered log of every action an agent performed |
| **Least-Privilege** | Design principle: agents receive the minimum tool access needed for their role |
| **Policy Violation** | Attempted action that exceeds the agent's MCP Access Policy |

### Responsibilities

- Define MCP tool access policies per agent type
- Enforce resource quotas on background agents (CPU/memory limits)
- Log all agent actions for audit and compliance
- Detect and report policy violations
- Publish audit events for compliance dashboards

### Domain Events

| Event | Trigger | Description |
|-------|---------|-------------|
| `AgentGovernance.PolicyViolated` | Agent attempts action beyond its policy | Policy violation detected and logged |
| `AgentGovernance.AccessDenied` | MCP layer rejects agent tool call | Tool call blocked by policy interceptor |
| `AgentGovernance.ResourceQuotaExceeded` | Agent exceeds CPU/memory limit | Agent throttled or terminated |
| `AgentGovernance.AuditLogEmitted` | Periodic or on-demand audit snapshot | Audit event published for compliance |

### Integration

- **Consumes from:** My Agents (agent lifecycle events, agent action streams)
- **Publishes to:** My Agents (deny/policy signals), incident tracker (for visibility), compliance dashboard
- **Pattern:** Policy evaluation interceptor in MCP layer; asynchronously audits all agent activity

---

## Context Map (Full Rufkis System)

```
                        ┌─────────────────────────────────────────┐
                        │           Desktop Shell (Wails)          │
                        │   Vue 3 UI ─── Pseudoterminal ── Auth   │
                        └────┬───────────────────────┬────────────┘
                             │                       │
                    ┌────────┘                       └────────┐
                    ▼                                         ▼
          ┌───────────────────┐             ┌──────────────────────┐
          │ Knowledge / Notes  │◄───────────┤ Terminal Drawer      │
          │ (local-first)      │ (Theme 4)  │ + Runbook Execution  │
          └─────┬─────────────┘             └────────┬─────────────┘
                │                                    │
                ▼                                    ▼
          ┌───────────────────┐             ┌──────────────────────┐
          │ Runbooks           │◄───────────┤ AI Copilot           │
          │ (operations/       │ (exec blocks,│ (output validation) │
          │  runbooks)         │  suggestions) └──────────────────────┘
          └─────┬─────────────┘
                │
                ▼
     ┌─────────────────────────────────────────┐
     │        Remediation (monitoring/rufkisai) │
     │  GitOps Bridge ── PR Generator ── Diff   │
     └──────────────┬──────────────────────────┘
                    │ PR contract
                    ▼
     ┌─────────────────────────────────────────┐
     │   Pipelines ──► RufkisCD (Argo CD)       │
     │   CI Build ──► PR Approval ──► Sync      │
     └─────────────────────────────────────────┘
                    ▲
                    │ PR contract
     ┌──────────────┴──────────────────────────┐
     │        FinOps Policy  ◄── Waste Heatmap  │
     │        Guardrails     ◄── Cost Explorer  │
     └─────────────────────────────────────────┘

     ┌───────────────────┐   ┌──────────────────────┐
     │ Incident Management│◄──┤ Agent Governance     │
     │ (NEW)              │   │ (NEW)                │
     │Receives:           │   │MCP policies, quotas  │
     │- Agent triage      │   │audit logs            │
     │- PR links          │   └────────┬─────────────┘
     │- Alert events      │            │
     └────────┬──────────┘            │
              │                       ▼
              │              ┌──────────────────────┐
              │              │ My Agents             │
              └──────────────┤ (agents/my-agents)    │
                             │ Watcher type +        │
                             │ lifecycle management  │
                             └──────────────────────┘
                                      │
                                      ▼
                             ┌──────────────────────┐
                             │ Monitoring (Anomstack)│
                             │ Anomaly detection     │
                             └──────────────────────┘
```

---

## Cross-Context: GitOps PR Contract

All PR-producing contexts (Remediation, FinOps Policy, Runbooks) implement this shared integration contract:

```yaml
pr_contract:
  title: "[Rufkis] <context>: <summary>"
  description:
    diagnosis: string
    remediation: string
    rollback: string
    origin_incident_id: string    # nullable; links to Incident Management
    generated_by: string          # "Remediation" | "FinOps" | "Runbook"
    confidence: string            # "low" | "medium" | "high"
  labels:
    - "rufkis"
    - "<context>"
```

No shared kernel — only this contract. Each context owns its PR generation logic independently.

---

*New bounded contexts generated from STRATEGY-2026-05-31.md analysis. Existing contexts (My Agents, Monitoring, Runbooks, Pipelines, RufkisCD, Waste Heatmap, Cost Explorer, Desktop Shell) are extended per the strategy but retain their existing boundaries.*
