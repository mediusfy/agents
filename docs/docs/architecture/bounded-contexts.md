# Rufkis — Bounded Contexts & Domain Architecture

> **Last updated:** 2026-06-02
> **Author:** Senior Business Analyst (DDD)

---

## Overview

Rufkis is a Kubernetes Operations Console with a monday.com-style UI. Built with Vue 3/TSX + Wails desktop, Tailscale networking, biometric authentication, and WebSocket real-time event streaming. This document defines the DDD Bounded Contexts, Ubiquitous Language, Integration Patterns, and Event Triggers.

### Architecture Principles

1. **Single in-process Event Bus** (Wails Go backend) — all contexts publish/subscribe typed domain events
2. **CQRS for FinOps** — local read-models cached per-region, write-side for budget mutation only
3. **Shared Kernel between Notifications & Tasks** — versioned state machine contract
4. **Anti-Corruption Layer between Agents ↔ Commands/Diagnostics** — capability tokens (not external calls)
5. **Customer-Supplier: GitOps → Workload Management** — GitOps supplies desired state, Workload Management never mutates cluster state directly
6. **Short-lived auth tokens (15 min)** with `AuthTokenRefreshed` event carrying `cloud_region` field

---

## Bounded Contexts

### 1. Workload Management Context

| Aspect | Detail |
|---|---|
| **Purpose** | Inspect and manage Kubernetes workloads (pods, deployments, services) with inline detail sheets. |
| **Owner** | SRE / Platform team |
| **Multi-cloud** | Cluster API endpoints are region-local; no cross-region data transfer for read operations. |
| **Integration** | **Customer** in Customer-Supplier with GitOps. Subscribes to `gitops.DesiredStateChanged`. Publishes `workload.ResourceInspected`, `workload.DeploymentScaled`, `workload.PodLogsStreamed`. |

**Ubiquitous Language**

| Term | Definition |
|---|---|
| *Workload Resource* | A Kubernetes resource type (Pod, Deployment, Service, DaemonSet, StatefulSet) |
| *Inline Detail Sheet* | An expandable panel within the list view showing full resource specs |
| *Scale Action* | Changing the replica count of a Deployment |
| *Log Stream* | Real-time pod log tailing with severity coloring |
| *Resource Status* | Health state: Running, Pending, CrashLoopBackOff, Evicted, etc. |

### 2. Diagnostics Context

| Aspect | Detail |
|---|---|
| **Purpose** | AI-powered cluster diagnostics for root cause analysis of anomalies. |
| **Owner** | SRE / AI Platform team |
| **Multi-cloud** | AI model inference can run locally (Wails desktop) or via a sidecar. Diagnostic data aggregated across all clusters but PII/data-residency filters apply. |
| **Integration** | Publishes `diagnostics.ClusterDiagnosticsCompleted`, `diagnostics.ScheduledDiagnosticsRun`. Consumed by: Notifications (alerts for critical findings), GitOps (remediation PR creation), Tasks (create follow-up tasks). Talks to Agents context via ACL. |

**Ubiquitous Language**

| Term | Definition |
|---|---|
| *Cluster Diagnostics* | An AI-driven analysis of cluster health, pod status, resource metrics, and event logs |
| *Finding* | A single issue identified by diagnostics, with severity, confidence score, and affected resource |
| *Confidence Score* | A percentage (0-100%) indicating how certain the AI is about a finding |
| *Scheduled Diagnostic* | A cron-triggered recurrence of cluster diagnostics |
| *Evidence* | Raw logs, metrics, and events that the AI used to determine a finding |

### 3. Agents Context

| Aspect | Detail |
|---|---|
| **Purpose** | Create, govern, and manage autonomous AI agents (SRE, Backend, Frontend, DevOps, Security) with MCP access policies. |
| **Owner** | Platform Administrator |
| **Multi-cloud** | Agents operate within their assigned cluster/region. Policy evaluation is local (capability tokens issued at auth time). |
| **Integration** | Publishes `agents.AgentCreated`, `agents.AgentPolicyUpdated`, `agents.HumanApprovalRequested`. Consumed by: Notifications (approval requests), Commands (agent execution), Real-time (agent status updates). Uses an **Anti-Corruption Layer** to translate MCP policies into internal command schemas. |

**Ubiquitous Language**

| Term | Definition |
|---|---|
| *Agent* | An autonomous AI assistant with a specific role (SRE, Backend, Frontend, DevOps, Security) |
| *Agent Type* | The role template: SRE, Backend, Frontend, DevOps, Security |
| *Agent Wizard* | A guided creation flow with pre-configured capabilities per agent type |
| *MCP Access Policy* | A policy defining which tools, namespaces, and resource types an agent can access |
| *Human Approval Request* | A governance action when an agent attempts an out-of-policy operation |
| *Capability Token* | A short-lived JWT issued at auth time containing the agent's allowed actions — validated locally (no external call) |
| *Policy Scope* | The allowed actions defined in an MCP policy (tools + namespaces + resource types) |

### 4. FinOps Context

| Aspect | Detail |
|---|---|
| **Purpose** | Monitor cloud spending, detect cost anomalies, set budgets, and trigger GitOps remediation. |
| **Owner** | FinOps / Finance team |
| **Multi-cloud** | ⚠️ **Data Residency Critical.** AWS Cost Explorer (pricing.us-east-1), Azure Retail Prices (global endpoint), GCP Cloud Billing (global) have different data locality. Uses **CQRS**: local read-models per region with configurable staleness TTL (5 min cost, 1 min usage). Circuit breakers per cloud provider with exponential backoff. `DataResidencyPolicy` is a **shared value object** passed by value into aggregates. |
| **Integration** | Publishes `finops.CostMetricsRefreshed`, `finops.CostAnomalyDetected`, `finops.BudgetThresholdReached`. Consumed by: Notifications (anomaly alerts), GitOps (remediation PRs), Tasks (follow-up tasks). |

**Ubiquitous Language**

| Term | Definition |
|---|---|
| *Burn Rate* | Daily cost consumption pace |
| *Cost Baseline* | Expected spend calculated from historical data and budgets |
| *Cost Anomaly* | Spend deviation >20% above baseline over a defined period |
| *Budget Threshold* | Alerting points at 50%, 80%, 100% of namespace budget |
| *DataResidencyPolicy* | A value object defining per-cloud-provider region restrictions and cache TTLs |
| *Read Model* | A local, cached, denormalized view of cost data optimized for dashboard display |
| *Projected Overage* | Predicted excess spend if the current burn rate continues |

### 5. GitOps Context

| Aspect | Detail |
|---|---|
| **Purpose** | Create, track, and manage remediation Pull Requests triggered by diagnostics findings and FinOps anomalies. |
| **Owner** | Platform / DevOps team |
| **Multi-cloud** | Git repos are connected per-cluster or per-region. PR metadata is local; no cross-region replication. |
| **Integration** | **Supplier** in Customer-Supplier with Workload Management. Publishes `gitops.RemediationPRCreated`, `gitops.RemediationPRStatusChanged`. Subscribes to `diagnostics.ClusterDiagnosticsCompleted`, `finops.CostAnomalyDetected`. |

**Ubiquitous Language**

| Term | Definition |
|---|---|
| *Remediation PR* | A GitHub/GitLab PR auto-generated from a diagnostic finding or cost anomaly |
| *Diff Preview* | A side-by-side comparison of the proposed Kubernetes manifest change |
| *PR Status* | Tracked states: Draft, Open, Merged, Closed |
| *Source Trigger* | The originating event (diagnostics or FinOps) that generated the PR |
| *Desired State* | The target Kubernetes manifest state defined in the Git repo |

### 6. Notifications Context

| Aspect | Detail |
|---|---|
| **Purpose** | Centralized, priority-coded alert system with configurable preferences per source. |
| **Owner** | All users |
| **Multi-cloud** | N/A — in-process event bus. No cross-region notification routing. |
| **Integration** | **Shared Kernel** with Tasks (versioned state machine contract: New→Acknowledged→Resolved→Archived). Publishes `notifications.AlertGenerated`, `notifications.PreferencesUpdated`. Subscribes to all domain events that produce alerts (Diagnostics, FinOps, Agents, GitOps). |

**Ubiquitous Language**

| Term | Definition |
|---|---|
| *Priority* | Alert severity level: Critical (red), High (orange), Medium (yellow), Low (gray) |
| *Alert Source* | The originating context: Diagnostics, FinOps, Agents, Workload, GitOps |
| *Notification Preference* | Per-source, per-priority toggle for delivering or suppressing alerts |
| *Alert Group* | Alerts aggregated by priority, sorted most-recent-first |
| *Bell Badge* | Unread alert count indicator on the notification icon |

### 7. Tasks Context

| Aspect | Detail |
|---|---|
| **Purpose** | Multi-step progress checklist task tracker, linkable to resources (deployments, agents, anomalies). |
| **Owner** | All users |
| **Multi-cloud** | N/A — local in-process data. |
| **Integration** | **Shared Kernel** with Notifications (versioned state machine). Publishes `tasks.TaskCreated`, `tasks.TaskStepCompleted`, `tasks.TaskLinkedToResource`. Consumed by: Notifications (task updates). |

**Ubiquitous Language**

| Term | Definition |
|---|---|
| *Task* | A tracked item with title, description, priority, assignee, and linked resource |
| *Checklist Step* | An ordered sub-item within a task with a completed/uncompleted state |
| *Progress Bar* | Visual indicator showing % of completed checklist steps |
| *Task Status* | State: Open (0 steps done), In Progress (some steps done), Done (all steps done) |
| *Resource Link* | Association between a task and a Kubernetes resource, agent, or anomaly |

### 8. Commands Context (Command Palette)

| Aspect | Detail |
|---|---|
| **Purpose** | Cmd-K command palette for quick navigation and action execution. |
| **Owner** | UX / All users |
| **Multi-cloud** | N/A — pure UI concern. |
| **Integration** | Subscribes to agent capabilities via **Anti-Corruption Layer** (commands are translated from MCP policies internally). Publishes `commands.CommandPaletteOpened`. |

**Ubiquitous Language**

| Term | Definition |
|---|---|
| *Command Palette* | An overlay search interface triggered by Cmd-K |
| *Command* | A navigable view or actionable item in the palette |
| *Fuzzy Match* | Real-time filtering of commands as the user types |
| *Shortcut Binding* | Keyboard shortcut assigned to a command or favorite |

### 9. Favorites Context

| Aspect | Detail |
|---|---|
| **Purpose** | User-favorited resources, agents, and views with keyboard shortcut access (Cmd+1–9). |
| **Owner** | All users |
| **Multi-cloud** | N/A — local user preference. |
| **Integration** | Publishes `favorites.ItemFavorited`, `favorites.ShortcutUsed`. Consumed internally. No cross-context coupling. |

**Ubiquitous Language**

| Term | Definition |
|---|---|
| *Favorite* | A starred view, resource, agent, or action for quick access |
| *Shortcut Number* | The Cmd+1 through Cmd+9 binding assigned to a favorite |
| *Star Icon* | UI toggle indicator showing favorited status (filled = favorited) |

### 10. Auth Context

| Aspect | Detail |
|---|---|
| **Purpose** | Biometric (fingerprint/FaceID) and Tailscale-based authentication with fallback. |
| **Owner** | Security / Platform team |
| **Multi-cloud** | Tailscale identity is global; issued capability tokens include a `cloud_region` claim. Biometric data stays on-device (OS-level). |
| **Integration** | Publishes `auth.UserAuthenticated`, `auth.AuthTokenRefreshed` (carries `cloud_region`). Consumed by Real-time (graceful WebSocket reconnection routing). Issues **capability tokens** for the Agents ACL. |

**Ubiquitous Language**

| Term | Definition |
|---|---|
| *Biometric Auth* | OS-level fingerprint or FaceID authentication |
| *Tailscale Auth* | Fallback authentication using Tailscale node identity |
| *Auth Token* | Short-lived JWT (15 min) with user claims and cloud_region |
| *Refresh Token* | Longer-lived token (24h) used to obtain new auth tokens |
| *Capability Token* | JWT issued at auth time containing the user's allowed MCP actions — validated locally in the Agents ACL |

### 11. Real-time Context

| Aspect | Detail |
|---|---|
| **Purpose** | WebSocket event streaming for live cluster state changes, alerts, and agent activities. |
| **Owner** | Backend / SRE team |
| **Multi-cloud** | WebSocket connections are region-pinned. On auth token refresh with region change, the connection is gracefully migrated. |
| **Integration** | Subscribes to `auth.AuthTokenRefreshed` for graceful reconnection routing. Publishes `realtime.WebSocketConnected`, `realtime.ClusterStateChanged`. Consumed by all UI views. Uses exponential backoff reconnection with one-time snapshot sync on reconnect. |

**Ubiquitous Language**

| Term | Definition |
|---|---|
| *WebSocket Connection* | Persistent bidirectional stream for real-time events |
| *Connection Status* | Indicator: Connected, Reconnecting (backoff), Disconnected |
| *Snapshot Sync* | A full state sync performed after reconnection to catch up on missed events |
| *Event Stream* | Typed domain events pushed over the WebSocket to the Vue frontend |
| *Exponential Backoff* | Reconnection delay increasing progressively (1s, 2s, 4s, 8s, ...) |

---

## Integration Patterns Summary

| Pattern | Contexts Involved | Details |
|---|---|---|
| **Shared Kernel** | Notifications + Tasks | Versioned `StateMachineContract` (semver). `StateMachineContractChanged` event for coordinated upgrades. Never force-migrate consumers simultaneously. |
| **Customer-Supplier** | GitOps (Supplier) → Workload Management (Customer) | GitOps is the single source of truth for desired state. Workload Management never mutates cluster state directly. |
| **Anti-Corruption Layer** | Agents ↔ Commands, Agents ↔ Diagnostics | Translates MCP policies into internal schemas. Uses local capability token validation (JWT decode + check, no external call). |
| **Event-Driven (Pub/Sub)** | All contexts via central Event Bus | Single in-process Event Bus in Wails Go backend. All contexts publish and subscribe using typed domain events. |
| **CQRS** | FinOps (read model vs write model) | Local read-models per region with configurable staleness TTL. Write-side only for budget mutation. Circuit breakers per cloud provider. |

---

## Multi-Cloud Constraints

### Data Residency

| Cloud Provider | Cost API Endpoint | Latency Profile | Data Locality |
|---|---|---|---|
| **AWS** | `pricing.us-east-1` | ~50-200ms from US regions, higher from EU/APAC | US-East only. Pricing data cached locally per region with TTL. |
| **Azure** | Retail Prices (global endpoint) | ~100-300ms globally | Single global endpoint. Apply DataResidencyPolicy value object to filter by region. |
| **GCP** | Cloud Billing (global) | ~100-250ms globally | Global. Use CQRS read-model cached locally. |

### Latency Mitigation

1. **FinOps CQRS**: Local read-models cached per-region with configurable TTL (cost: 5 min, usage: 1 min)
2. **Circuit Breakers**: Per cloud-provider endpoint with exponential backoff (initial: 1s, max: 60s)
3. **DataResidencyPolicy**: Shared value object passed by value — no cross-service calls for policy evaluation
4. **Region-Pinned WebSockets**: Real-time connections stay within the user's region; `AuthTokenRefreshed` event carries `cloud_region` for graceful migration

### Auth & Tailscale Across Clouds

- Tailscale identity is globally recognized — no per-region re-authentication needed
- Short-lived auth tokens (15 min) carry a `cloud_region` claim
- On token refresh, if `cloud_region` changes, the WebSocket handler gracefully migrates the connection to the new regional endpoint
- Capability tokens (for Agents ACL) are issued at auth time and validated locally — no cross-region auth calls
