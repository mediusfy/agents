# Rufkis — Domain Event Catalog

> **Product**: Rufkis — Kubernetes Operations Console with monday.com-style UI
> **Last Updated**: 2026-06-02

---

## Event Conventions

- **Naming**: past-tense, namespaced: `{bounded-context}.{EventName}`
- **Ownership**: one bounded context produces the event; many may consume it
- **Schema**: all events carry `eventId` (uuid), `timestamp` (ISO8601), `source` (bounded context name)
- **Resilience**: events are delivered at-least-once; consumers must be idempotent
- **Multi-Cloud**: events carrying resource data include `geoRegion` and `dataResidencyZone` fields

---

## Event Catalog

### 1. Cluster Management Events

| Event | Description | Payload Sketch | Consumers |
|-------|-------------|---------------|-----------|
| `cluster-mgmt.ClusterConnected` | New K8s cluster connected and validated | `{ clusterId, clusterName, kubeconfigFingerprint, k8sVersion, cloudProvider, region, nodeCount, connectedAt }` | ResourceCatalog, LiveStatus, BoardEngine, AccessControl, AuditTrail |
| `cluster-mgmt.ClusterDisconnected` | Cluster connection removed or revoked | `{ clusterId, previousHealth, disconnectedAt, reason }` | ResourceCatalog, LiveStatus, AlertSystem, AuditTrail |
| `cluster-mgmt.ClusterHealthChanged` | Cluster connectivity health transition | `{ clusterId, previousStatus, newStatus (Connected/Degraded/Offline), lastHealthyAt, degradedAt, reason, geoRegion }` | LiveStatus, AlertSystem, BoardEngine, Visualization |
| `cluster-mgmt.ClusterDiscovered` | Initial resource inventory gathered | `{ clusterId, namespaceCount, nodeCount, resourceCountByKind, discoveredAt }` | ResourceCatalog, SearchEngine, AuditTrail |
| `cluster-mgmt.CrossClusterViewGenerated` | Cross-cluster federated view rendered | `{ sessionId, clustersIncluded[], filterCriteria, resultCount, geoRegion, generatedAt }` | AuditTrail, Analytics |

### 2. Board Engine Events

| Event | Description | Payload Sketch | Consumers |
|-------|-------------|---------------|-----------|
| `board-engine.BoardCreated` | New board instantiated | `{ boardId, clusterId, namespace, templateId, columnConfig, createdBy, createdAt }` | TemplateStore, AccessControl, AuditTrail |
| `board-engine.BoardRendered` | Board view loaded in UI | `{ boardId, clusterId, namespace, viewType (board/timeline/calendar/map/gallery), resourceCount, columnCount, renderedAt }` | AuditTrail, Analytics, Observability |
| `board-engine.CardMoved` | Resource card dragged to new status column | `{ cardId, resourceKind, resourceName, namespace, clusterId, fromStatus, toStatus, reconciled (boolean), movedBy, movedAt }` | ResourceCatalog (state change), LiveStatus, AuditTrail, AlertSystem |
| `board-engine.ColumnConfigurationChanged` | Board columns modified | `{ boardId, modifiedBy, addedColumns[], removedColumns[], reorderMap, changedAt }` | BoardEngine (re-render), TemplateStore, AuditTrail |
| `board-engine.BoardReconciled` | 15s drift reconciliation completed | `{ boardId, clusterId, cardsChecked, cardsCorrected, driftCount, reconciledAt }` | AuditTrail, Observability |

### 3. Resource Catalog Events

| Event | Description | Payload Sketch | Consumers |
|-------|-------------|---------------|-----------|
| `resource-catalog.ResourceCreated` | K8s resource created via UI | `{ resourceId, resourceKind, resourceName, namespace, clusterId, apiVersion, manifestHash, mode (form/yaml), createdBy, createdAt }` | BoardEngine (add card), AuditTrail, Billing, Policy, Notifications |
| `resource-catalog.ResourceUpdated` | K8s resource modified via UI | `{ resourceId, resourceKind, resourceName, namespace, clusterId, diffSummary, previousManifestHash, updatedBy, updatedAt }` | BoardEngine (update card), AuditTrail, GitOpsBridge, AlertSystem |
| `resource-catalog.ResourceDeleted` | K8s resource deleted via UI | `{ resourceId, resourceKind, resourceName, namespace, clusterId, preDeleteManifestHash, cascade (boolean), deletedBy, deletedAt }` | BoardEngine (remove card), AuditTrail, AlertSystem, Billing |
| `resource-catalog.DeletionBlocked` | Deletion of protected resource attempted | `{ resourceId, resourceKind, resourceName, namespace, clusterId, blockedByUserId, reason, timestamp }` | AuditTrail, AlertSystem, AccessControl |
| `resource-catalog.ManifestValidationFailed` | YAML manifest failed validation | `{ userId, resourceKind, resourceName, clusterId, validationErrors[], attemptedManifestHash, failedAt }` | AuditTrail, Observability |

### 4. Live Status Events

| Event | Description | Payload Sketch | Consumers |
|-------|-------------|---------------|-----------|
| `live-status.ResourceHealthChanged` | Resource health status transition | `{ resourceId, resourceKind, resourceName, namespace, clusterId, previousHealth, currentHealth, previousStatus, currentStatus, restartCount, errorMessage, transitionedAt, geoRegion }` | BoardEngine (badge update), AlertSystem, Visualization, AutomationAgent |
| `live-status.WebSocketConnectionStateChanged` | WebSocket connection lifecycle | `{ sessionId, clusterId, previousState, currentState (connected/disconnected/reconnecting), droppedAt, reconnectedAt, missedEventsCount }` | BoardEngine (UI banner), Observability |
| `live-status.EventBatchProcessed` | Batch of health events delivered | `{ sessionId, clusterId, batchSize, processingTimeMs, processedAt }` | Observability, Analytics |

### 5. Visualization Events

| Event | Description | Payload Sketch | Consumers |
|-------|-------------|---------------|-----------|
| `visualization.TimelineViewGenerated` | Gantt timeline rendered | `{ boardId, clusterId, timeRange, resourceCount, groupBy (kind/namespace), zoomLevel, generatedAt }` | AuditTrail, Analytics |
| `visualization.CalendarViewRendered` | Calendar view loaded | `{ boardId, clusterId, viewMode (monthly/weekly/daily), entryCount, entryTypes[], renderedAt }` | AuditTrail, Analytics |
| `visualization.MapViewGenerated` | Multi-cluster topology map rendered | `{ boardId, clustersIncluded[], nodeCount, connectionCount, latencyMetrics{}, generatedAt }` | AuditTrail, Analytics |
| `visualization.GalleryViewGenerated` | Gallery view loaded | `{ boardId, clusterId, namespace, layoutMode (grid/list), cardCount, renderedAt }` | AuditTrail, Analytics |
| `visualization.ViewSwitched` | User switched between view types | `{ boardId, userId, fromView, toView, currentFilters, switchedAt }` | AuditTrail, Analytics |

### 6. Search Engine Events

| Event | Description | Payload Sketch | Consumers |
|-------|-------------|---------------|-----------|
| `search-engine.SearchExecuted` | Global search or filter applied | `{ sessionId, query, filtersApplied{}, resultCount, executionTimeMs, geoRegion, executedAt }` | AuditTrail, Analytics |
| `search-engine.SavedViewCreated` | Filter combination saved as named view | `{ savedViewId, name, filters{}, viewType, createdBy, createdAt }` | AuditTrail |
| `search-engine.SearchIndexUpdated` | Search index refreshed from cluster data | `{ clusterId, resourceCount, indexSizeBytes, indexingTimeMs, updatedAt }` | Observability |

### 7. Access Control Events

| Event | Description | Payload Sketch | Consumers |
|-------|-------------|---------------|-----------|
| `access-control.RBACConfigurationChanged` | Team/role/permission changes | `{ configType (team/role/policy), modifiedBy, affectedTeams[], affectedPolicies[], changedAt }` | All contexts (permission cache invalidation), AuditTrail |
| `access-control.PermissionDenied` | Operation denied by RBAC | `{ userId, action, resourceKind, resourceName, namespace, clusterId, deniedAt, reason }` | AuditTrail, AlertSystem |
| `access-control.TeamMemberAdded` | User added to team | `{ teamId, teamName, userId, userEmail, role, addedBy, addedAt }` | AuditTrail |
| `access-control.TeamMemberRemoved` | User removed from team | `{ teamId, teamName, userId, userEmail, removedBy, removedAt }` | AuditTrail |

### 8. Template Store Events

| Event | Description | Payload Sketch | Consumers |
|-------|-------------|---------------|-----------|
| `template-store.TemplateCreated` | New board template saved | `{ templateId, name, scope (personal/team/global), columnConfig, defaultView, createdBy, createdAt }` | BoardEngine, SearchEngine, AuditTrail |
| `template-store.TemplateUpdated` | Existing template modified | `{ templateId, version, changesSummary, updatedBy, updatedAt }` | BoardEngine (update badge), AuditTrail |
| `template-store.TemplateApplied` | Board created from a template | `{ templateId, boardId, appliedBy, appliedAt }` | BoardEngine, AuditTrail, Analytics |

### 9. GitOps Bridge Events

| Event | Description | Payload Sketch | Consumers |
|-------|-------------|---------------|-----------|
| `gitops-bridge.PullRequestCreated` | GitOps PR generated for remediation | `{ prId, repoUrl, branch, baseBranch, title, resourceKind, resourceName, namespace, clusterId, diffUrl, labels[], createdBy, createdAt }` | BoardEngine (PR badge), AlertSystem, AuditTrail |
| `gitops-bridge.PullRequestMerged` | GitOps PR merged | `{ prId, mergeCommitSHA, mergedBy, mergedAt }` | ResourceCatalog, AlertSystem, AuditTrail |
| `gitops-bridge.RemediationCompleted` | GitOps sync completed successfully | `{ prId, resourceKind, resourceName, namespace, clusterId, previousState, currentState, healthStatus, completedAt }` | BoardEngine (badge update), AlertSystem (resolve alert), AuditTrail |
| `gitops-bridge.RemediationFailed` | GitOps sync or PR creation failed | `{ prId, resourceRef, failureReason, failedAt }` | AlertSystem, AuditTrail |

### 10. Automation Agent Events

| Event | Description | Payload Sketch | Consumers |
|-------|-------------|---------------|-----------|
| `automation-agent.AgentCreated` | New automation agent registered | `{ agentId, name, triggerType, actionType, conditions[], rateLimit, createdBy, createdAt }` | LiveStatus (register watcher), AccessControl, AuditTrail |
| `automation-agent.AgentUpdated` | Agent configuration changed | `{ agentId, changesSummary, updatedBy, updatedAt }` | LiveStatus, AuditTrail |
| `automation-agent.AgentDeleted` | Automation agent removed | `{ agentId, deletedBy, deletedAt }` | LiveStatus (unregister), AuditTrail |
| `automation-agent.AgentActionExecuted` | Agent triggered and executed action | `{ agentId, actionType, resourceTarget, beforeState, afterState, success (boolean), executionTimeMs, executedAt }` | AlertSystem, AuditTrail, BoardEngine |
| `automation-agent.AgentRateLimited` | Agent action skipped due to rate limit | `{ agentId, triggerCount, rateLimitThreshold, nextAvailableAt, skippedAt }` | AlertSystem, AuditTrail |
| `automation-agent.AgentTriggerFired` | Agent trigger condition met (before action) | `{ agentId, triggerType, triggerEvent, resourceRef, firedAt }` | AuditTrail, Analytics |

### 11. Alert System Events

| Event | Description | Payload Sketch | Consumers |
|-------|-------------|---------------|-----------|
| `alert-system.AlertTriggered` | Priority alert fired | `{ alertId, priority (P0-P4), title, clusterId, resourceRefs[], triggerEvent, suggestedAction, triggeredAt }` | NotificationDelivery, PagerDuty, Slack, SMS, BoardEngine (banner), Email |
| `alert-system.AlertAcknowledged` | Alert acknowledged by operator | `{ alertId, acknowledgedBy, channel, acknowledgedAt }` | NotificationDelivery (stop retries), BoardEngine (dismiss banner) |
| `alert-system.AlertEscalated` | Alert escalated to next on-call tier | `{ alertId, previousTier, newTier, escalationReason, escalatedAt }` | PagerDuty, NotificationDelivery, BoardEngine |
| `alert-system.AlertResolved` | Alert condition cleared | `{ alertId, resolvedBy (system/user), resolutionNote, resolvedAt }` | NotificationDelivery, BoardEngine (clear banner), AuditTrail |
| `alert-system.MaintenanceWindowCreated` | Maintenance window scheduled | `{ windowId, clusterId, startsAt, endsAt, reason, affectedResources[], createdBy, createdAt }` | AlertSystem (silence alerts), Visualization (Calendar), AuditTrail |
| `alert-system.MaintenanceWindowEnded` | Maintenance window expired | `{ windowId, clusterId, endedAt }` | AlertSystem (resume alerts) |

### 12. Audit Trail Events

| Event | Description | Payload Sketch | Consumers |
|-------|-------------|---------------|-----------|
| `audit-trail.AuditEntryCreated` | Immutable record of any operation | `{ entryId, timestamp, actor (userId, ip, sessionId), action (VIEW/READ/CREATE/UPDATE/DELETE/SEARCH/EXPORT), resourceRef (kind, name, namespace, cluster, UID), payloadHash (SHA256), status (success/failure), httpStatus, geoRegion, previousEntryHash, entryHash }` | SIEM, Compliance, Analytics, Observability |
| `audit-trail.ChainLinkAppended` | New hash-chained entry confirmed | `{ entryId, chainPosition, previousHash, currentHash, chainedAt }` | Compliance, SIEM (tamper detection) |
| `audit-trail.IntegrityCheckPerformed` | Hash chain verification completed | `{ checkId, entriesChecked, chainValid (boolean), firstCorruptedEntry (if any), checkedAt }` | Compliance, AlertSystem |

---

## Event Flow Diagram (Key Paths)

```
ClusterManagement                 AlertSystem
    │                                  ▲
    │ ClusterHealthChanged             │ AlertTriggered
    ▼                                  │
LiveStatus ──► ResourceHealthChanged ──┤
    │                                  │
    │ WebSocket                        │
    ▼                                  │
BoardEngine ◄──────────────────────────┘
    │ CardMoved
    ▼
ResourceCatalog ──► GitOpsBridge ──► PullRequestCreated
    │                                      │
    │ ResourceCreated/Updated/Deleted       │ RemediationCompleted
    ▼                                      ▼
AuditTrail ◄────────────────────────── BoardEngine (badge update)
    ▲
    │ (All contexts publish here)
    └─────────────────────────────────┐
                                      │
AutomationAgent ──► Watch health ─────┘
    │ AgentActionExecuted
    ▼
AlertSystem
```

---

## Data Residency in Events

All events carrying resource or cluster data MUST include:
- `geoRegion`: The geographic region derived from the cluster metadata or actor's IP
- `dataResidencyZone`: The canonical storage zone (e.g., `eu`, `us`, `ap`)

Consumer contexts MUST:
1. Filter events by `dataResidencyZone` before processing
2. Route events to zone-local event buses where required by regulation
3. Never cache or persist cross-zone event data in the wrong zone
