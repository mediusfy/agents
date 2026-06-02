

# Rufkis — Kubernetes Operations Console

## Architecture & Domain-Driven Design Document

### Overview
Rufkis is a desktop-native Kubernetes operations console built with **Vue 3/TSX + Wails**, featuring a **monday.com-style** UI. It provides workload management, AI diagnostics, autonomous agent lifecycle management, FinOps monitoring, GitOps-native remediation, and a rich UX with command palette, favorites, and real-time WebSocket streaming.

**Tech Stack:**
- **Desktop Runtime:** Wails (Go backend + native window)
- **Frontend:** Vue 3 + TypeScript + TSX
- **Networking:** Tailscale (mesh VPN for multi-cluster access)
- **Auth:** Biometric (fingerprint/face) + WebAuthn
- **Real-time:** WebSocket event streaming
- **Infrastructure:** Tailscale + WireGuard-based connectivity

---

## 1. Bounded Contexts

### 1.1 WorkloadView Context
- **Ubiquitous Language:** Workload, Pod, Deployment, Service, Namespace, Inline Detail Sheet, Manifest, Replicas, Env Vars, Image Tag
- **Responsibilities:** CRUD viewing/editing of Kubernetes workloads; inline detail sheet rendering; real-time resource metrics streaming
- **Integration Patterns:** 
  - **Shared Kernel** with ClusterContext (API server connectivity)
  - **Event Publisher** to GitOpsPR Context (for edits creating PRs)
- **Owned Events:** `workloads.WorkloadListRetrieved`, `workloads.WorkloadDetailSheetOpened`, `workloads.DeploymentEditInitiated`

### 1.2 Diagnostics Context
- **Ubiquitous Language:** Diagnostic, Analysis, AI Engine, Remediation, Severity Label, Threshold Breach, Fix Manifest
- **Responsibilities:** Triggering cluster diagnostics; interfacing with LLM for analysis; generating remediation suggestions
- **Integration Patterns:**
  - **Customer-Supplier** with AI/LLM Provider (external)
  - **Event Publisher** to GitOpsPR Context (Apply Fix → PR)
  - **Event Publisher** to Notifications Context
- **Owned Events:** `diagnostics.DiagnosticTriggered`, `diagnostics.AnalysisCompleted`, `diagnostics.RemediationApplied`

### 1.3 AgentCreation Context
- **Ubiquitous Language:** Agent Type (SRE, Backend, Frontend, DevOps, Security), Wizard, Step, Capability, MCP Policy, LLM Provider, Provisioning
- **Responsibilities:** Multi-step wizard flow; agent type templates; validation; deployment orchestration
- **Integration Patterns:**
  - **Event Publisher** to Orchestration Context (deploy)
  - **Event Publisher** to Governance Context (MCP policy write)
- **Owned Events:** `agentcreation.AgentTypeSelected`, `agentcreation.CapabilitiesConfigured`, `agentcreation.AgentDeploymentRequested`

### 1.4 AgentOrchestration Context
- **Ubiquitous Language:** Agent Deployment, Kubernetes Manifest, ConfigMap, Agent Runtime
- **Responsibilities:** Provisioning agent Kubernetes deployments; writing MCP policies as ConfigMaps; managing agent lifecycle
- **Integration Patterns:**
  - **Conformist** to AgentCreation Context (takes deployment specs)
  - **Event Publisher** to Governance Context
- **Owned Events:** `orchestration.AgentProvisioned`

### 1.5 FinOps Context
- **Ubiquitous Language:** Cost Breakdown, Namespace Cost, Cluster Cost, Hourly Spend, Anomaly, Spike, Optimization, Timeline
- **Responsibilities:** Real-time cost data ingestion; anomaly detection (>20% spikes); cost timeline visualization; optimization recommendations
- **Integration Patterns:**
  - **Open-Host Service** (WebSocket cost stream consumer)
  - **Event Publisher** to Notifications Context
  - **Event Publisher** to GitOpsPR Context
- **Owned Events:** `finops.CostStreamReceived`, `finops.CostAnomalyDetected`, `finops.InvestigationInitiated`, `finops.CostTimelineGenerated`

### 1.6 GitOpsPR Context
- **Ubiquitous Language:** Pull Request, GitOps Repository, Diff, Branch, Manifest, ArgoCD, Sync, Merge, Approve, Reject
- **Responsibilities:** Automated PR generation; PR review interface; ArgoCD integration; sync status tracking
- **Integration Patterns:**
  - **Anti-Corruption Layer** around GitHub/GitLab APIs
  - **Event Publisher** to Notifications Context
  - **Event Publisher** to TaskTracker Context
- **Owned Events:** `gitops.PullRequestCreated`, `gitops.PullRequestApproved`, `gitops.PullRequestMerged`, `gitops.PullRequestRejected`

### 1.7 Governance Context
- **Ubiquitous Language:** MCP (Model Context Protocol) Policy, Access Policy, Agent, Audit Log, Violation, Action Denied, Compliance
- **Responsibilities:** MCP policy management; policy validation (conflict detection); runtime action interception; audit logging
- **Integration Patterns:**
  - **Shared Kernel** with AgentRuntime (policy enforcement point)
  - **Event Publisher** to Notifications Context
  - **Open-Host Service** for audit log queries
- **Owned Events:** `governance.AgentMCPPolicyModified`, `governance.PolicyConflictDetected`, `governance.ActionDenied`, `governance.AuditLogEntryCreated`

### 1.8 Notifications Context
- **Ubiquitous Language:** Notification, Alert, Severity (CRITICAL/HIGH/MEDIUM/LOW), Toast, Bell, Priority-Coded, Snooze, Dismiss, Read
- **Responsibilities:** Central notification ingestion; severity routing; UI rendering (toast for CRITICAL); persistence; filtering
- **Integration Patterns:**
  - **Event Publisher** to UI (WebSocket push)
  - **Event Consumer** from all other contexts
- **Owned Events:** `notifications.NotificationCreated`, `notifications.NotificationRead`, `notifications.NotificationSnoozed`, `notifications.NotificationDismissed`

### 1.9 TaskTracker Context
- **Ubiquitous Language:** Task, Step, Progress, Checklist, Status (pending/running/completed/failed), Duration, Logs, Retry
- **Responsibilities:** Tracking multi-step operations; progress bars; step status updates; failure handling; retry orchestration
- **Integration Patterns:**
  - **Event Consumer** from all operation-emitting contexts
  - **Shared Kernel** with Notifications Context
- **Owned Events:** `tasks.TaskCreated`, `tasks.StepStatusChanged`, `tasks.TaskFailed`, `tasks.TaskRetryRequested`, `tasks.TaskCompleted`

### 1.10 CommandPalette Context
- **Ubiquitous Language:** Command Palette, ⌘K, Ctrl+K, Query, Result, Filter, Shortcut Hint, Action
- **Responsibilities:** Keyboard shortcut capture; real-time search/filter; action execution
- **Integration Patterns:**
  - **Published Language** interface across all contexts (each context registers actions)
- **Owned Events:** `palette.CommandPaletteOpened`, `palette.QueryChanged`, `palette.ResultSelected`

### 1.11 Favorites Context
- **Ubiquitous Language:** Favorite, Star, Shortcut Key (1-9), Rename, Reorder, Sync
- **Responsibilities:** Favorite CRUD; keyboard shortcut assignment; cross-session sync via WebSocket
- **Integration Patterns:**
  - **Event Publisher** to WebSocket Sync Service
- **Owned Events:** `favorites.FavoriteAdded`, `favorites.FavoriteModified`, `favorites.FavoriteNavigated`

### 1.12 Auth Context
- **Ubiquitous Language:** Biometric Auth, WebAuthn, Session, Fingerprint, Face ID, Desktop Credential
- **Responsibilities:** Biometric authentication via platform WebAuthn; session management; Tailscale identity integration
- **Integration Patterns:**
  - **Shared Kernel** with Wails Desktop (native credential APIs)
- **Owned Events:** `auth.UserAuthenticated`, `auth.UserLoggedOut`, `auth.SessionExpired`

---

## 2. Integration Patterns Between Bounded Contexts

| Source Context | Target Context | Pattern | Mechanism |
|---|---|---|---|
| WorkloadView | GitOpsPR | Event Publisher | Domain Events via message bus |
| Diagnostics | GitOpsPR | Event Publisher | `diagnostics.RemediationApplied` → `gitops.PullRequestCreated` |
| Diagnostics | Notifications | Event Publisher | Direct event emission |
| AgentCreation | AgentOrchestration | Conformist | Agent spec contract |
| AgentOrchestration | Governance | Event Publisher | `orchestration.AgentProvisioned` |
| FinOps | Notifications | Event Publisher | Anomaly alerts |
| FinOps | GitOpsPR | Event Publisher | Cost optimization PRs |
| GitOpsPR | Notifications | Event Publisher | PR lifecycle events |
| GitOpsPR | TaskTracker | Event Publisher | Multi-step status |
| Governance | Notifications | Event Publisher | Violation alerts |
| Governance | AgentRuntime | Shared Kernel | MCP policy enforcement |
| TaskTracker | Notifications | Shared Kernel | Task failure events |
| All Contexts | CommandPalette | Published Language | Registered actions |
| Favorites | WebSocket Sync | Event Publisher | Cross-session sync |
| Auth | All Contexts | Shared Kernel | Session token |
| Wails Desktop | Auth | Shared Kernel | Native biometric API |

---

## 3. Multi-Cloud & Data Residency Constraints

### 3.1 Data Residency
- Cost data (FinOps) MUST remain in the region of the cluster being monitored (GDPR/ePrivacy compliance)
- Diagnostic analysis payloads sent to LLM providers MUST be scrubbed of PII/identifiable cluster metadata
- Agent MCP policies are stored locally per-cluster, with optional regional aggregation
- Notification history is stored in the user's desktop-local SQLite (managed by Wails), never shipped cross-region

### 3.2 Network Latency
- WebSocket connections are established via Tailscale direct connections (peer-to-peer where possible)
- For clusters behind NATs, Tailscale DERP relay servers are used with <100ms target latency
- Command palette search is local-first (index cached in desktop), no network hop for filtering

### 3.3 Tailscale Integration
- Each Rufkis desktop instance authenticates via Tailscale identity
- Cluster access is mediated through Tailscale SSH or Kubernetes Tailscale operator
- Multi-cluster switching uses Tailscale's MagicDNS for service discovery

---

## 4. Event Triggers Master Table

| ID | Event Name | Owner Context | Consumers | Payload Sketch |
|---|---|---|---|---|
| EVT-01 | `workloads.WorkloadListRetrieved` | WorkloadView | AuditLog, Observability | `{ namespaceFilter, workloads[] }` |
| EVT-02 | `workloads.WorkloadDetailSheetOpened` | WorkloadView | ResourceUsage, LogStream, K8sEvents | `{ kind, name, namespace }` |
| EVT-03 | `workloads.DeploymentEditInitiated` | WorkloadView | GitOpsPR, AuditLog | `{ deployment, changes }` |
| EVT-04 | `diagnostics.DiagnosticTriggered` | Diagnostics | AI Engine, TaskTracker | `{ clusterId, triggerType }` |
| EVT-05 | `diagnostics.AnalysisCompleted` | Diagnostics | UI, Notifications | `{ analysisId, summary, remediations[] }` |
| EVT-06 | `diagnostics.RemediationApplied` | Diagnostics | GitOpsPR, Notifications | `{ analysisId, fixManifestRef }` |
| EVT-07 | `agentcreation.AgentTypeSelected` | AgentCreation | Analytics | `{ agentType }` |
| EVT-08 | `agentcreation.CapabilitiesConfigured` | AgentCreation | Governance | `{ agentType, mcpPolicies }` |
| EVT-09 | `agentcreation.AgentDeploymentRequested` | AgentCreation | AgentOrchestration | `{ spec, mcpPolicies }` |
| EVT-10 | `orchestration.AgentProvisioned` | AgentOrchestration | Governance, AgentCreation | `{ agentId, configMapRef }` |
| EVT-11 | `finops.CostStreamReceived` | FinOps | Anomaly Detection | `{ namespace, cost, timestamp }` |
| EVT-12 | `finops.CostAnomalyDetected` | FinOps | Notifications, UI | `{ workload, spike, threshold }` |
| EVT-13 | `gitops.PullRequestCreated` | GitOpsPR | Notifications, TaskTracker | `{ prUrl, repo, diff }` |
| EVT-14 | `gitops.PullRequestMerged` | GitOpsPR | Notifications, TaskTracker | `{ prUrl, result }` |
| EVT-15 | `gitops.PullRequestRejected` | GitOpsPR | Notifications | `{ prUrl, reason }` |
| EVT-16 | `governance.AgentMCPPolicyModified` | Governance | AgentRuntime, AuditLog | `{ agentId, newPolicy }` |
| EVT-17 | `governance.ActionDenied` | Governance | Notifications, AuditLog | `{ agentId, attemptedAction }` |
| EVT-18 | `governance.AuditLogEntryCreated` | AuditLog | Compliance | `{ agentId, action, result }` |
| EVT-19 | `notifications.NotificationCreated` | Notifications | UI (WebSocket) | `{ severity, message, sourceBc }` |
| EVT-20 | `notifications.NotificationDismissed` | Notifications | UI | `{ notificationId }` |
| EVT-21 | `tasks.TaskCreated` | TaskTracker | UI | `{ taskId, steps[] }` |
| EVT-22 | `tasks.StepStatusChanged` | TaskTracker | UI, Notifications | `{ taskId, stepId, status }` |
| EVT-23 | `tasks.TaskFailed` | TaskTracker | Notifications, UI | `{ taskId, failedStep, reason }` |
| EVT-24 | `tasks.TaskCompleted` | TaskTracker | UI, Notifications | `{ taskId }` |
| EVT-25 | `palette.CommandPaletteOpened` | CommandPalette | Analytics | `{}` |
| EVT-26 | `palette.QueryChanged` | CommandPalette | Search Index | `{ query }` |
| EVT-27 | `palette.ResultSelected` | CommandPalette | Target Context | `{ resultId, type }` |
| EVT-28 | `favorites.FavoriteAdded` | Favorites | Sync Service, UI | `{ resourceType, resourceId }` |
| EVT-29 | `favorites.FavoriteModified` | Favorites | Sync Service, UI | `{ action, itemId }` |
| EVT-30 | `favorites.FavoriteNavigated` | Favorites | Navigation | `{ shortcutKey, itemId }` |
| EVT-31 | `auth.UserAuthenticated` | Auth | All Contexts | `{ userId, method }` |
| EVT-32 | `auth.UserLoggedOut` | Auth | All Contexts | `{ userId }` |
