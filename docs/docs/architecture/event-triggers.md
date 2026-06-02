# Rufkis — Event Triggers Catalog

> **Last updated:** 2026-06-02
> **Author:** Senior Business Analyst (DDD)

---

## Legend

| Column | Description |
|---|---|
| **Event ID** | Unique identifier |
| **Event Name** | Past-tense namespaced name, e.g. `workload.DeploymentScaled` |
| **Owner Context** | The bounded context that owns/publishes this event |
| **Consumers** | Which bounded contexts consume this event |
| **Payload Sketch** | Key fields in the event payload |
| **Triggered By** | The user action or system condition that fires this event |

---

## Event Triggers Table

| ID | Event Name | Owner Context | Consumers | Payload Sketch | Triggered By |
|---|---|---|---|---|---|
| EVT-WORKLOAD-01 | `workload.ResourceInspected` | Workload Management | Diagnostics (potential), Real-time | `{ resourceType, resourceName, namespace, clusterId, userId, timestamp }` | User opens inline detail sheet |
| EVT-WORKLOAD-02 | `workload.DeploymentScaled` | Workload Management | GitOps (desired state sync), Notifications, Real-time | `{ deploymentName, namespace, clusterId, oldReplicas, newReplicas, userId, timestamp }` | User scales deployment from detail sheet |
| EVT-WORKLOAD-03 | `workload.PodLogsStreamed` | Workload Management | Real-time | `{ podName, namespace, clusterId, containerName, userId, timestamp }` | User initiates pod log stream |
| EVT-DIAG-01 | `diagnostics.ClusterDiagnosticsCompleted` | Diagnostics | Notifications (critical alerts), GitOps (remediation PRs), Tasks (follow-ups) | `{ clusterId, findings: [{ severity, confidence, resource, description, evidence }], runId, timestamp }` | User clicks "Run Cluster Diagnostics" or scheduled trigger fires |
| EVT-DIAG-02 | `diagnostics.ScheduledDiagnosticsRun` | Diagnostics | Notifications, GitOps, Tasks | `{ clusterId, scheduleId, findings, runId, isScheduled: true, timestamp }` | Cron-based scheduler triggers diagnostic run |
| EVT-AGENTS-01 | `agents.AgentCreated` | Agents | Notifications (confirmation), Real-time (status update) | `{ agentId, agentName, agentType, capabilities, mcpPolicyId, userId, timestamp }` | User completes Agent Creation Wizard |
| EVT-AGENTS-02 | `agents.AgentPolicyUpdated` | Agents | Agents (self), Real-time, Audit Log | `{ agentId, policyId, changes: { toolsAdded, toolsRemoved, namespacesGranted, namespacesRevoked }, userId, timestamp }` | User modifies agent MCP access policy |
| EVT-AGENTS-03 | `agents.HumanApprovalRequested` | Agents | Notifications (priority alert), Tasks | `{ requestId, agentId, intendedAction, affectedResource, policyViolation, userId, timestamp }` | Agent attempts out-of-policy action |
| EVT-FINOPS-01 | `finops.CostMetricsRefreshed` | FinOps | Real-time (dashboard updates) | `{ clusterId, namespaceBreakdown, totalSpend, burnRate, forecast, timestamp }` | Dashboard loads or scheduled refresh |
| EVT-FINOPS-02 | `finops.CostAnomalyDetected` | FinOps | Notifications (anomaly alert), GitOps (remediation PR), Tasks | `{ anomalyId, namespace, resource, deviationPercentage, baseline, actual, projectedOverage, timeWindow, timestamp }` | Cost spending deviates >20% above baseline |
| EVT-FINOPS-03 | `finops.BudgetThresholdReached` | FinOps | Notifications (budget alert) | `{ budgetId, namespace, threshold (50|80|100), currentSpend, budgetAmount, percentageUsed, timestamp }` | Actual spend hits budget threshold |
| EVT-GITOPS-01 | `gitops.RemediationPRCreated` | GitOps | Notifications (confirmation), Workload Management (desired state), Tasks | `{ prId, prUrl, sourceTrigger: { type: "diagnostics"|"finops", sourceId }, targetResource, diffSummary, status: "open", timestamp }` | User creates remediation PR from finding/anomaly |
| EVT-GITOPS-02 | `gitops.RemediationPRStatusChanged` | GitOps | Notifications (status update), Workload Management (desired state sync), Tasks (auto-resolve) | `{ prId, prUrl, oldStatus, newStatus ("open"|"merged"|"closed"), sourceTrigger, timestamp }` | External PR status change detected |
| EVT-NOTIF-01 | `notifications.AlertGenerated` | Notifications | Real-time (push to UI), Tasks (if configured) | `{ alertId, priority: "critical"|"high"|"medium"|"low", source, title, description, contextLink, timestamp }` | Any system component generates a priority-coded alert |
| EVT-NOTIF-02 | `notifications.PreferencesUpdated` | Notifications | Notifications (self — preference evaluation) | `{ userId, preferences: { source: { priority: boolean } } }` | User updates notification preferences |
| EVT-TASKS-01 | `tasks.TaskCreated` | Tasks | Notifications (task created alert), Real-time | `{ taskId, title, priority, assignee, steps: [{ id, description, completed }], linkedResource, timestamp }` | User creates new task |
| EVT-TASKS-02 | `tasks.TaskStepCompleted` | Tasks | Notifications (progress update), Real-time | `{ taskId, stepId, stepsCompleted, totalSteps, progressPercent, newStatus ("open"|"in_progress"|"done"), timestamp }` | User checks off a task step |
| EVT-TASKS-03 | `tasks.TaskLinkedToResource` | Tasks | Real-time | `{ taskId, resourceType, resourceId, resourceLink, timestamp }` | User creates task linked from finding/anomaly |
| EVT-CMD-01 | `commands.CommandPaletteOpened` | Commands | Analytics (usage tracking) | `{ userId, viewContext, timestamp }` | User presses Cmd-K |
| EVT-FAV-01 | `favorites.ItemFavorited` | Favorites | UI (state change) | `{ userId, itemType, itemId, shortcutNumber, action: "add"|"remove", timestamp }` | User stars/unstars an item |
| EVT-FAV-02 | `favorites.ShortcutUsed` | Favorites | Analytics (usage tracking) | `{ userId, shortcutNumber, itemId, itemType, timestamp }` | User presses Cmd+1..9 |
| EVT-AUTH-01 | `auth.UserAuthenticated` | Auth | Real-time (WebSocket init), Audit Log | `{ userId, authMethod: "biometric"|"tailscale"|"password", cloudRegion, issuedTokenExp, timestamp }` | User successfully authenticates |
| EVT-AUTH-02 | `auth.AuthTokenRefreshed` | Auth | Real-time (graceful reconnection routing) | `{ userId, oldRegion, newRegion, newTokenExp, timestamp }` | Auth token refresh (every 15 min) |
| EVT-REALTIME-01 | `realtime.WebSocketConnected` | Real-time | UI (connection status indicator) | `{ userId, region, connectionId, timestamp }` | WebSocket connection established |
| EVT-REALTIME-02 | `realtime.ClusterStateChanged` | Real-time | All UI views (live updates) | `{ changeType: "pod_restarted"|"deployment_scaled"|"alert", resource, payload, timestamp }` | Upstream cluster event received via WebSocket |

---

## Event Flow Diagram (Text)

```
┌─────────────┐     ┌──────────────┐     ┌──────────────┐
│   Auth      │────>│  Real-time   │<────│  Workload    │
└──────┬──────┘     └──────┬───────┘     └──────┬───────┘
       │                   │                     │
       │                   │                     │
       ▼                   ▼                     ▼
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│  Agents      │    │  Diagnostics │    │   FinOps     │
│  (ACL)       │    │              │    │              │
└──────┬───────┘    └──────┬───────┘    └──────┬───────┘
       │                   │                     │
       │         ┌─────────┴─────────┐           │
       │         │                   │           │
       ▼         ▼                   ▼           ▼
┌──────────────────────────────────────────────────────┐
│                   Event Bus (In-Process)              │
│          Wails Go Backend — Typed Domain Events        │
└──────┬──────────┬──────────┬──────────┬──────────────┘
       │          │          │          │
       ▼          ▼          ▼          ▼
┌──────────┐ ┌────────┐ ┌────────┐ ┌────────┐
│Notific.  │ │ GitOps │ │ Tasks  │ │Favorites│
│(Shared   │ │(Supplier│ │(Shared │ │         │
│ Kernel)  │ │  → WLM) │ │ Kernel)│ │         │
└──────────┘ └────────┘ └────────┘ └────────┘
```

> **Key:** Solid arrows = event publish. Dashed = subscription/consumption. ACL = Anti-Corruption Layer.
