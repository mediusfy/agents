# Rufkis Dashboard — Domain-Driven Design Analysis

## Overview

Analysis of the Rufkis Dashboard redesign requirements, decomposed into bounded contexts, user stories, event triggers, and integration patterns. Multi-cloud constraints (data residency, regional latency) are flagged where applicable.

---

## 1. Bounded Contexts

### 1.1 `Dashboard` (Core UI Context)
**Ubiquitous Language:**
| Term | Definition |
|------|-----------|
| **Card** | A visual representation of a Kubernetes resource (Pod, Deployment, Service, Node) on the Kanban board |
| **Column** | A status lane on the Kanban board (Pending, Running, Failed, Unknown) |
| **Kanban Board** | The primary layout widget organizing cards into draggable columns |
| **Health Summary Bar** | Top-of-page widget showing aggregated cluster/node/pod counts |
| **Theme** | Visual appearance — "dark" or "light" mode |
| **Namespace Filter** | Dropdown control scoping the board to a single Kubernetes namespace |
| **Terminal Panel** | Embedded bottom panel providing direct kubectl access |

**Responsibilities:**
- Render Kanban layout with draggable cards
- Display live node-status indicators (colored dots)
- Host the embedded terminal panel
- Provide namespace filtering
- Render cluster health summary at top
- Manage dark/light theme toggle and persistence

**Multi-Cloud Constraint:** Dashboard must be region-aware — if the operator is viewing clusters in `us-east-1` and `eu-west-2`, the health summary and terminal sessions must respect data residency (no cross-border kubectl proxy without explicit consent, per GDPR/SOC2).

---

### 1.2 `ClusterManagement` (Observability Context)
**Ubiquitous Language:**
| Term | Definition |
|------|-----------|
| **Node** | A Kubernetes cluster node (control-plane or worker) |
| **NodeStatus** | The Ready condition of a node (True / False / Unknown) |
| **Pod** | A Kubernetes pod running on a node |
| **PodStatus** | The phase of a pod (Running / Pending / Failed / Succeeded / Unknown) |
| **Heartbeat** | The last time a node reported to the control plane |

**Responsibilities:**
- Watch Kubernetes API for node/pod status transitions
- Emit `nodes.NodeConditionChanged`, `cluster.NodeStatusChanged`, `cluster.PodStatusChanged`
- Aggregate cluster health metrics

**Multi-Cloud Constraint:** For multi-region deployments, each region's `ClusterManagement` context MUST run locally in-region to avoid control-plane latency. Cross-region aggregation emits events only to the `Dashboard` context via an Anti-Corruption Layer (ACL) that strips PII.

---

### 1.3 `Terminal` (Session Context)
**Ubiquitous Language:**
| Term | Definition |
|------|-----------|
| **Session** | An interactive kubectl terminal session scoped to a specific cluster context |
| **Command** | A single kubectl invocation within a session |
| **Cluster Context** | The target cluster for kubectl commands (kubeconfig context) |

**Responsibilities:**
- Proxy WebSocket-based terminal streams
- Enforce RBAC (who can run kubectl on which cluster)
- Audit-log every command for compliance
- Terminate sessions on panel close or timeout

**Multi-Cloud Constraint:** Terminal sessions MUST only proxy through a gateway in the same region as the target cluster. Cross-region terminal access requires explicit user confirmation and audit logging (latency + data sovereignty concern).

---

### 1.4 `UserPreferences` (Persistence Context)
**Ubiquitous Language:**
| Term | Definition |
|------|-----------|
| **ThemePreference** | The user's selected visual theme (dark or light) |
| **Storage** | Currently `localStorage`; future: cloud-synced per user profile |

**Responsibilities:**
- Persist and restore theme toggle preference
- (Future) Sync preferences across browser sessions

---

### 1.5 `Audit` (Compliance Context)
**Responsibilities:**
- Record all state-changing user actions (card moves, terminal commands, filter changes)
- Provide immutable event log for SOC2 / compliance audits

---

## 2. Bounded Context Integration Patterns

| Source Context | Target Context | Pattern | Details |
|---------------|---------------|---------|---------|
| `ClusterManagement` | `Dashboard` | **Anti-Corruption Layer (ACL)** | Raw K8s events are transformed into dashboard-friendly `cluster.NodeStatusChanged` and `cluster.PodStatusChanged` events. The ACL strips in-region PII/metadata before forwarding cross-region. |
| `ClusterManagement` | `Terminal` | **Customer-Supplier** | Terminal context uses cluster metadata from `ClusterManagement` to validate the `clusterContext` a user connects to. `ClusterManagement` is the upstream supplier. |
| `Dashboard` | `Audit` | **Event Publisher** | All user-initiated events (`CardMoved`, `TerminalCommandExecuted`, `ThemeToggled`, `NamespaceFilterApplied`) are published onto an Audit event stream. `Audit` consumes asynchronously. |
| `Dashboard` | `UserPreferences` | **Shared Kernel (Local)** | Theme preference is a simple string (`"dark"`/`"light"`) shared between contexts. Currently local-only; future uses a shared repository. |
| `Dashboard` | `Terminal` | **Shared Kernel** | Both contexts share the `sessionId` and `clusterContext` types. Terminal panel embedded in Dashboard UI is a co-located integration. |

---

## 3. User Stories

### DASH-01: Kanban Drag-and-Drop
**As a** cluster operator
**I want** a Kanban-style layout with drag-and-drop cards
**So that** I can visually organize and prioritize Kubernetes workloads by status

**Acceptance Criteria (Gherkin):**
```gherkin
Given the Rufkis dashboard is loaded
 And the Kanban board displays columns: "Pending", "Running", "Failed", "Unknown"
When I drag a card representing a Kubernetes resource from "Pending" to "Running"
Then the card snaps into the "Running" column
 And the underlying resource status changes to Running
 And the change is persisted in the backend state
 And a success toast notification appears

Given the user has dragged a card
When the backend update fails (e.g., network timeout)
Then the card returns to its original column
 And an error toast notification appears
 And the event dashboard.ResourceCardSnapped is NOT emitted
```

**Event Triggers:**
- `dashboard.ResourceDragStarted` — drag initiated
- `dashboard.ResourceCardDropped` — card released onto target column
- `resources.ResourceStatusTransitionRequested` — backend mutation requested
- `resources.ResourceStatusChanged` — backend successfully persisted
- `dashboard.ResourceCardSnapped` — UI confirms visual snap

---

### DASH-02: Live Node Status Indicators
**As a** cluster operator
**I want** live status indicators per Kubernetes cluster node
**So that** I can instantly detect node-level anomalies without refreshing

**Acceptance Criteria (Gherkin):**
```gherkin
Given the Rufkis dashboard is rendering cluster nodes
When a node's Ready condition transitions from True to False
Then the corresponding card's status indicator changes from green to red within 5 seconds
 And a tooltip displays: "Node lost heartbeat at <timestamp>. Reason: <lastError>"

Given the dashboard is open
When a node transitions back to Ready
Then the indicator changes from red to green within 5 seconds

Given a node has not reported for 60 seconds
When the node transitions to Unknown
Then the indicator changes to amber/gray
 And a tooltip displays: "Node has not reported since <timestamp>"
```

**Event Triggers:**
- `nodes.NodeConditionChanged` — any node condition transitions
- `nodes.NodeNotReady` — specialized sub-event for Ready=False transitions

---

### DASH-03: Embedded Terminal Panel
**As a** cluster operator
**I want** an embedded terminal panel with direct kubectl access
**So that** I can execute ad-hoc commands without switching context

**Acceptance Criteria (Gherkin):**
```gherkin
Given I am on the Rufkis dashboard
When I click the terminal icon
Then an embedded terminal panel opens at the bottom of the screen
 And the active cluster context is displayed in the terminal prompt

Given the terminal panel is open
When I type "kubectl get pods" and press Enter
Then the command output streams back in real time
 And the command is recorded in the audit log

Given the terminal panel is open
When I press Ctrl+`
Then focus is transferred to the terminal input

Given the terminal panel is open
When I click the close button
Then the terminal session is terminated
 And the panel collapses
 And a confirmation toast appears if any commands were executed

Given the terminal panel is open
When the session is idle for 15 minutes
Then the session is automatically terminated
 And the panel collapses
 And a notification reads: "Terminal session timed out due to inactivity"
```

**Event Triggers:**
- `dashboard.TerminalSessionOpened` — session initiated
- `dashboard.TerminalCommandExecuted` — individual command run
- `dashboard.TerminalSessionClosed` — session ended

---

### DASH-04: Namespace Filtering
**As a** cluster operator
**I want** to filter the Kanban board by namespace
**So that** I can focus on workloads in a specific scope

**Acceptance Criteria (Gherkin):**
```gherkin
Given the Rufkis dashboard shows all namespaces by default
When I select "production" from the namespace filter dropdown
Then only cards with namespace="production" are visible on the Kanban board
 And the health summary at the top recalculates for the "production" scope only
 And all column counts reflect only "production" resources

Given the namespace filter is set to "production"
When I clear the filter (select "All Namespaces")
Then all namespace cards are shown again
 And the health summary returns to cluster-wide scope

Given the namespace filter is set to "production"
When a namespace-scoped resource transitions state
Then only the filtered Kanban board updates accordingly
```

**Event Triggers:**
- `dashboard.NamespaceFilterApplied` — filter set to a specific namespace
- `dashboard.NamespaceFilterCleared` — filter reset to all

---

### DASH-05: Cluster Health Summary
**As a** cluster operator
**I want** a cluster health summary bar at the top of the dashboard
**So that** I can assess overall cluster status at a glance

**Acceptance Criteria (Gherkin):**
```gherkin
Given the Rufkis dashboard is loaded
Then a health summary bar is displayed at the top showing:
 | Metric | Display |
 |--------|---------|
 | Total Nodes | N (with counts: Ready X / NotReady Y / Unknown Z) |
 | Total Pods | N (with counts: Running A / Pending B / Failed C) |
 | Cluster Version | v1.28.x |
 | Uptime | Xd Yh Zm |

When a node transitions from Ready to NotReady
Then the health summary updates within 5 seconds
 And the node count ticks adjust: Ready -1, NotReady +1

When the namespace filter is active
Then the health summary reflects ONLY resources in the filtered namespace
```

**Event Triggers:**
- `cluster.NodeStatusChanged` — node health transition
- `cluster.PodStatusChanged` — pod phase transition
- `dashboard.HealthSummaryUpdated` — aggregated view re-rendered

---

### DASH-06: Dark/Light Theme Toggle
**As a** cluster operator
**I want** a dark/light theme toggle
**So that** I can reduce eye strain during extended monitoring sessions

**Acceptance Criteria (Gherkin):**
```gherkin
Given the Rufkis dashboard is open in light mode
When I click the theme toggle icon (moon icon) in the header
Then the UI switches to dark mode instantly
 And the toggle icon changes to a sun icon
 And the preference is persisted in localStorage

Given the user has selected dark mode
When I reload the page
Then the page loads in dark mode
 And no flash of incorrect theme occurs

Given the theme preference is stored in localStorage
When I open the dashboard on a different browser/device
Then the default theme (light) is shown
 (Theme is not yet cloud-synced)
```

**Event Triggers:**
- `dashboard.ThemeToggled` — user toggled theme
- `dashboard.ThemeRestored` — theme restored from persistence on page load

---

## 4. Complete Event Map

| Event | Owner (BC) | Consumers | SLA |
|-------|-----------|-----------|-----|
| `dashboard.ResourceDragStarted` | Dashboard | Dashboard UI, Audit | Real-time |
| `dashboard.ResourceCardDropped` | Dashboard | Dashboard UI, Audit | Real-time |
| `resources.ResourceStatusTransitionRequested` | Dashboard | ClusterManagement | Real-time |
| `resources.ResourceStatusChanged` | ClusterManagement | Dashboard, Audit, QA | ≤2s |
| `dashboard.ResourceCardSnapped` | Dashboard | Dashboard UI | ≤500ms |
| `nodes.NodeConditionChanged` | ClusterManagement | Dashboard, Alerting, NodeHealthHistory | ≤5s |
| `nodes.NodeNotReady` | ClusterManagement | Dashboard, Alerting, Billing (SLA credits) | ≤5s |
| `dashboard.TerminalSessionOpened` | Terminal | Dashboard UI, Audit, SessionManagement | Real-time |
| `dashboard.TerminalCommandExecuted` | Terminal | Dashboard UI (output stream), Audit, CommandHistory | Real-time |
| `dashboard.TerminalSessionClosed` | Terminal | Dashboard UI, Audit, SessionManagement, Billing | Real-time |
| `dashboard.NamespaceFilterApplied` | Dashboard | Dashboard UI, ClusterManagement (health recalc) | Real-time |
| `dashboard.NamespaceFilterCleared` | Dashboard | Dashboard UI, ClusterManagement (health recalc) | Real-time |
| `cluster.NodeStatusChanged` | ClusterManagement | Dashboard (health summary) | ≤5s |
| `cluster.PodStatusChanged` | ClusterManagement | Dashboard (health summary) | ≤5s |
| `dashboard.HealthSummaryUpdated` | Dashboard | Dashboard UI (internal) | ≤5s from source event |
| `dashboard.ThemeToggled` | Dashboard | Dashboard UI, Analytics | Real-time |
| `dashboard.ThemeRestored` | Dashboard | Dashboard UI | ≤100ms on page load |

---

## 5. Multi-Cloud Constraints (Flagged Items)

| ID | Constraint | Impact |
|----|-----------|--------|
| **MC-01** | **Data Residency** — Node/Pod payloads from EU clusters MUST NOT transit through US-based infrastructure | ClusterManagement ACL must strip or mask node names/pod names before cross-region forwarding to Dashboard |
| **MC-02** | **Terminal Proximity** — kubectl sessions MUST proxy through a gateway in the same region as the target cluster | Terminal's SessionManagement must select the nearest WebSocket proxy; cross-region sessions require consent |
| **MC-03** | **Latency Budget** — Dashboard health summary MUST update within 5s even when aggregating across regions (US-East + EU-West) | ClusterManagement must use regional event hubs with cross-region aggregation only at the summary level, not per-node |
| **MC-04** | **Audit Locality** — Terminal command audit logs must be stored in the region where the command was executed | Audit BC must tag each log entry with `region` and enforce regional retention policies (GDPR right to deletion) |

## 6. Ambiguity Flags

| Flag | Issue | Recommendation |
|------|-------|---------------|
| **AMB-01** | The requirements do not specify what happens when a card is dropped into a column representing a status that the underlying K8s resource does not support (e.g., dropping a `DaemonSet` into "Pending") | Define a validation matrix mapping K8s resource types to valid status columns. If a drop is invalid, reject with a clear error toast. |
| **AMB-02** | No mention of multi-cluster support — does the dashboard show one cluster at a time or aggregate multiple? | Clarify whether the dashboard scope is a single cluster (assumed in this analysis) or multi-cluster. If multi-cluster, the namespace filter becomes `{cluster, namespace}`. |
| **AMB-03** | No mention of write permissions — can any user drag cards to change resource status, or is this read-only organization? | Clarify RBAC model. Recommendation: drag-and-drop changes the VISUAL column only for unprivileged users; write-back to K8s requires edit permissions. |
