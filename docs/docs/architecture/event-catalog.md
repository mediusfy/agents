


# Rufkis — Domain Event Catalog

Each event is past-tense, namespaced by owning Bounded Context. Payloads are sketched in TypeScript-like syntax.

---

## Identity & Access Context

| Event | Payload Sketch | Consumers |
|-------|---------------|-----------|
| `identity.TailscaleIdentityDetected` | `{ deviceId, tailscaleUser, tailscaleIP }` | Biometric auth prompt |
| `identity.BiometricAuthSucceeded` | `{ userId, tailscaleIdentity, authMethod: 'touchid'|'hello'|'faceid', timestamp }` | Session initialization |
| `identity.UserLoggedIn` | `{ userId, sessionId, timestamp }` | Console UX, WebSocket init |
| `identity.BiometricAuthFailed` | `{ userId?, tailscaleIdentity, failureCount, deviceId, timestamp }` | Lockout counter, Notification |
| `identity.BiometricAuthThresholdReached` | `{ deviceId, failureCount: 3, lockoutDuration: 60, timestamp }` | App lock, Notification (P3) |
| `security.AppLocked` | `{ deviceId, lockoutUntil }` | Console UX (block UI) |
| `connectivity.WebSocketEstablished` | `{ sessionId, userId, clusterEndpoints[] }` | All real-time subscribers |

---

## Cluster Monitoring Context

| Event | Payload Sketch | Consumers |
|-------|---------------|-----------|
| `cluster.ConsoleSessionInitialized` | `{ sessionId, userId, clusterCount }` | Dashboard render |
| `cluster.ClusterSnapshotFetched` | `{ namespaces: [{ name, pods[], deployments[], services[] }] }` | Overview grid |
| `cluster.WorkloadStatusChanged` | `{ workloadId, workloadType, namespace, oldStatus, newStatus, timestamp }` | Dashboard tile, Notification (P2 if crash), Agent reactivation |
| `cluster.WorkloadDetailRequested` | `{ workloadId, workloadType, namespace, userId }` | Analytics, Audit |

---

## AI Diagnostics Context

| Event | Payload Sketch | Consumers |
|-------|---------------|-----------|
| `cluster.AIDiagnosticRequested` | `{ diagnosticId, workloadId, namespace, errorType, clusterStateSnapshot, userId, timestamp }` | LLM inference engine |
| `cluster.DiagnosticsCompleted` | `{ diagnosticId, rootCauseSummary, remediationSteps[], confidenceScore }` | UI detail panel, GitOps Remediation |
| `cluster.DiagnosticFixApplied` | `{ diagnosticId, workloadId, fixDescription, prUrl, userId }` | GitOps Remediation, Audit |

---

## Agent Management Context

| Event | Payload Sketch | Consumers |
|-------|---------------|-----------|
| `agents.AgentDeployInitiated` | `{ agentSpec: { type, name, permissions, mcpPolicies } }` | Kubernetes API provisioner |
| `agents.AgentDeployed` | `{ agentId, agentType, name, namespace, mcpPolicies, userId, timestamp }` | Agent fleet UI, Notification (P4) |
| `agents.AgentHealthChanged` | `{ agentId, oldHealth, newHealth, lastError?, timestamp }` | Fleet UI, Notification (P1 if Down), Task creation |
| `agents.McpPolicyUpdated` | `{ agentId, oldPolicy, newPolicy, updatedBy, timestamp }` | OPA/Gatekeeper sync, Audit |
| `agents.UnauthorizedActionBlocked` | `{ agentId, attemptedAction, resource, policyViolated, timestamp }` | Audit, Notification (P3) |

---

## FinOps Context

| Event | Payload Sketch | Consumers |
|-------|---------------|-----------|
| `finops.CostAnomalyDetected` | `{ anomalyId, workloadId, namespace, deviationPct, currentCost, expectedCost, estimatedMonthlyImpact, suggestedActions[], timestamp }` | FinOps dashboard, Notification (P2), AI Diagnostics |
| `finops.BudgetRuleCreated` | `{ ruleId, scope, budgetAmount, thresholds, remediationAction }` | Cost engine, Budget watcher |
| `finops.BudgetThresholdBreached` | `{ ruleId, scope, thresholdLevel, currentCost, remediationAction, timestamp }` | Remediation executor, Notification (P2/P3) |

---

## GitOps Remediation Context

| Event | Payload Sketch | Consumers |
|-------|---------------|-----------|
| `gitops.RemediationActionTriggered` | `{ remediationId, source: 'diagnostic'|'finops'|'manual', sourceEventId, targetResource }` | PR generation engine |
| `gitops.FixPullRequestCreated` | `{ prId, prUrl, repo, branch, diffSummary, sourceContext, author, timestamp }` | UI (show PR link), Notification (P4) |
| `gitops.PullRequestMerged` | `{ prId, prUrl, mergedBy, mergeMethod, timestamp }` | UI (status update), ArgoCD/Flux webhook |
| `gitops.AutoMergeInitiated` | `{ prId, prUrl, autoMergePolicy }` | Git provider API (auto-approve + merge) |

---

## Notification Context

| Event | Payload Sketch | Consumers |
|-------|---------------|-----------|
| `notifications.SystemEventOccurred` | `{ sourceEventType, sourceEventId, rawPayload }` | Notification router |
| `notifications.NotificationPrioritized` | `{ notificationId, priority: 'P1'|'P2'|'P3'|'P4', title, message }` | Delivery channel selector |
| `notifications.NotificationCreated` | `{ notificationId, priority, title, message, sourceEventType, sourceEventId, targetRoute, timestamp }` | Notification store |
| `notifications.CriticalPushRequired` | `{ notificationId, title, message, targetRoute }` | Desktop toast + sound service |
| `notifications.HighPushRequired` | `{ notificationId, title, message, targetRoute }` | Desktop toast service |
| `notifications.TrayNotificationCreated` | `{ notificationId, title, message }` | In-app tray |
| `notifications.SilentNotificationCreated` | `{ notificationId }` | Notification dot indicator |
| `notifications.NotificationAcknowledged` | `{ notificationId, userId, timestamp }` | Notification store, Analytics |
| `notifications.NotificationGroupedForDisplay` | `{ groups: { P1: [], P2: [], P3: [], P4: [] } }` | Bell icon UI |

---

## Task Tracker Context

| Event | Payload Sketch | Consumers |
|-------|---------------|-----------|
| `tasks.TaskCreated` | `{ taskId, title, steps[], createdBy, sourceIncidentId?, timestamp }` | Task tracker UI, Notification |
| `tasks.RunbookGenerated` | `{ incidentId, runbookId, taskList[], generatedAt }` | Task tracker UI |
| `tasks.TaskSubStepToggled` | `{ taskId, stepId, newCompleted, toggledBy, timestamp }` | UI state, Audit |
| `tasks.TaskCompleted` | `{ taskId, completedBy, duration, timestamp }` | Notification, Incident tracker |
| `tasks.TaskLinkOpened` | `{ taskId, linkUrl, linkType, openedBy, timestamp }` | Analytics, Audit |

---

## Console UX Context

| Event | Payload Sketch | Consumers |
|-------|---------------|-----------|
| `console.CommandPaletteOpened` | `{ userId, sessionId, originContext }` | Analytics, UserPreferences |
| `console.CommandSearchExecuted` | `{ userId, query, resultCount, resultsReturned[] }` | Analytics, SearchIndex |
| `console.CommandResultSelected` | `{ userId, selectedItem: { type, label, target }, actionType }` | Audit, RBAC, CommandExecution |
| `console.CheatSheetDisplayed` | `{ userId, sessionId }` | Analytics, Onboarding |
| `ui.FavoriteAdded` | `{ favoriteId, resourceType, resourceId, label, position, userId }` | UserPreference store |
| `ui.FavoriteRemoved` | `{ favoriteId, userId }` | UserPreference store |
