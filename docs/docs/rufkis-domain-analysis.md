

# Rufkis — Domain-Driven Design Analysis
> Generated: 2025-03-26
> Kubernetes Operations Console with monday.com-style UI

---

## 1. Bounded Contexts

### 1.1 `ClusterConnect` — Cluster Connection & Lifecycle
**Ubiquitous Language:**
| Term | Definition |
|------|-----------|
| Cluster | A Kubernetes cluster identified by name, cloud provider, and region |
| Kubeconfig | A YAML file containing cluster API endpoints and credentials |
| Heartbeat | A periodic connectivity check (every 30s) against the K8s API health endpoint |
| Connection Status | One of: `Connected` (green), `Degraded` (yellow — missed 1 heartbeat), `Disconnected` (red — 5 min unreachable) |
| Cluster Tag | Short identifier string like `aws-us-east-1` displayed on board items |

**Integration Patterns:**
- **Shared Kernel** with `ResourceSync`: shares the cluster registry and API client pool
- **Customer-Supplier** to `BoardEngine`: supplies cluster list for board scope filtering
- **Domain Event**: `clusterconnect.ClusterConnected`, `clusterconnect.ClusterDisconnected`

### 1.2 `ResourceSync` — Kubernetes Resource Discovery & Watching
**Ubiquitous Language:**
| Term | Definition |
|------|-----------|
| Resource | A K8s object (Pod, Deployment, Service, StatefulSet, Node, Namespace, ConfigMap, Secret) |
| Watch | A long-lived HTTP/2 connection to the K8s API for real-time change events |
| Sync Cycle | A periodic full-list refresh (every 60s) to catch missed watch events |
| Resource Snapshot | An in-memory cache of discovered resources with their current status |
| Status Pill | A color-coded visual indicator: Green (healthy/ready), Yellow (progressing/pending), Red (error/crash) |

**Integration Patterns:**
- **Anti-Corruption Layer (ACL)** between K8s API versions and Rufkis internal models
- **Event Publisher** to `BoardEngine`, `Monitor`, `Alerting` via `resourcesync.ResourceStateChanged`
- **Open-Host Service** providing a gRPC stream for WebSocket broadcast to frontends

### 1.3 `BoardEngine` — Board Configuration & Views
**Ubiquitous Language:**
| Term | Definition |
|------|-----------|
| Board | A user-defined view of K8s resources with columns, groups, and filters |
| Item | A row in the board representing one K8s resource |
| Column | A field definition: Status (color pill), Text, Numeric, Date, Person, Timeline, Health expression |
| Column Mapping | A JSONPath expression or computed function that extracts/derives column values from resource data |
| Group | A logical collection of items, e.g., grouped by `namespace`, `cluster`, or `team` label |
| View Type | Render mode: `Board` (table), `Kanban` (swimlanes by status), `Timeline` (horizontal bars), `Calendar` |
| View Switcher | UI element allowing an SRE to toggle between view types without losing data context |

**Integration Patterns:**
- **Shared Kernel** with `ResourceSync`: column mappings reference resource field paths
- **Customer** of `ClusterConnect` and `ResourceSync`: consumes cluster status and resource state
- **Published Language**: column definitions are JSON-serializable for frontend hydration

### 1.4 `OpsAction` — Operational Actions on Resources
**Ubiquitous Language:**
| Term | Definition |
|------|-----------|
| Action | An operation performed on a K8s resource: Scale, Restart, Delete, Logs, Exec |
| Action Modal | A dialog that opens on right-click, pre-filled with current resource values |
| Scale Operation | Changing `.spec.replicas` on a Deployment or StatefulSet |
| Pod Restart | Deleting a Pod to trigger ReplicaSet recreation (or annotation-based rollout restart) |
| Exec Session | A browser-based terminal session (xterm.js) connected to a container via K8s exec API |
| Log Stream | A WebSocket-proxied stream of container stdout/stderr, filterable by severity |

**Integration Patterns:**
- **Conformist** to K8s API: executes raw API calls, maps responses back to domain events
- **Customer** of `AccessGovernance`: checks user role before executing any action
- **Published Events**: `ops.ScaleInitiated`, `ops.ScaleCompleted`, `ops.PodRestartInitiated`, `ops.PodLogsRequested`, `ops.ContainerExecInitiated`

### 1.5 `Monitor` — Health & Compliance Columns
**Ubiquitous Language:**
| Term | Definition |
|------|-----------|
| Health Expression | A boolean expression (e.g., `readyReplicas == replicas`) evaluated against resource state |
| Health Column | A board column that auto-computes green/red based on the health expression |
| Breach | When a health expression evaluates to false, triggering state propagation |
| Compliance Check | A policy rule (e.g., "all Deployments must have >= 2 replicas") evaluated across resources |

**Integration Patterns:**
- **Customer** of `ResourceSync`: consumes `ResourceStateChanged` to re-evaluate health expressions
- **Supplier** to `Alerting`: emits `monitor.HealthColumnBreach` when conditions degrade

### 1.6 `Alerting` — Alert Rules & Notifications
**Ubiquitous Language:**
| Term | Definition |
|------|-----------|
| Alert Rule | A threshold condition defined by: `{Column} {Operator} {Value} for {Duration}` |
| Severity | One of: `Info`, `Warning`, `Critical` |
| Degradation | A resource entering a non-healthy state (crash loop, node pressure, cert expiry) |
| Notification Channel | Destination: In-App, Slack, PagerDuty, Email |
| Escalation Path | A sequence of SREs/teams notified if an alert is not acknowledged |

**Integration Patterns:**
- **Customer** of `Monitor` and `ResourceSync`: subscribes to degradation events
- **Published Language**: alert rule definitions are JSON with CRUD via REST API
- **Supplier** to external notification services (Slack webhook, PagerDuty API)

### 1.7 `AccessGovernance` — RBAC & Permissions
**Ubiquitous Language:**
| Term | Definition |
|------|-----------|
| Role | One of: `Admin` (full control), `Editor` (modify board, perform ops), `Viewer` (read-only) |
| Board Scope | Permissions are assigned per user per board |
| Server-Side Enforcement | All operations are validated server-side; frontend merely reflects permissions |
| Access Denied | Emitted as a domain event when an unauthorized operation is attempted |

**Integration Patterns:**
- **Supplier** to `OpsAction` and `BoardEngine`: provides authorization checks
- **Shared Kernel** with User Identity (from identity provider / SSO)

### 1.8 `AuditLog` — Activity Logging
**Ubiquitous Language:**
| Term | Definition |
|------|-----------|
| Activity Entry | A record: `{timestamp, actor, action, target, oldValue, newValue}` |
| Append-Only | Logs cannot be edited, deleted, or tampered with (immutable) |
| Data Residency | Audit logs must be stored only in allowed regions per `Residency` policy |

**Integration Patterns:**
- **Customer** of all contexts: subscribes to all `*.*` domain events for recording
- **Conformist** to `Residency`: applies data residency constraints when persisting log entries

### 1.9 `Residency` — Multi-Cloud Data Residency
**Ubiquitous Language:**
| Term | Definition |
|------|-----------|
| Allowed Region | A cloud region approved for operational data storage (e.g., `aws-us-east-1`, `gcp-eu-central-1`) |
| Data Residency Policy | A configuration mapping of region → allowed/denied for data persistence |
| Enforcement Guard | Interceptor in the persistence layer that rejects writes to disallowed regions |
| Violation | An attempt to persist data in a non-compliant region; triggers an alert |

**Integration Patterns:**
- **Supplier** to `AuditLog`, `BoardEngine`, `Assignment`: provides storage region enforcement
- **Published Event**: `residency.DataResidencyViolation` consumed by `Alerting` and `AuditLog`

---

## 2. Context Map & Integration Patterns

```
┌─────────────────────┐         ┌──────────────────────┐
│    ClusterConnect    │──S/K──▶│     ResourceSync      │
│   (cluster mgmt)    │         │   (K8s discovery)     │
└─────────┬───────────┘         └────────┬──────────────┘
          │ C/S                           │ EVT
          ▼                               ▼
┌─────────────────────┐         ┌──────────────────────┐
│     BoardEngine      │◀──EVT──│       Monitor         │
│   (views/columns)    │         │  (health columns)     │
└─────────┬───────────┘         └────────┬──────────────┘
          │ EVT                           │ EVT
          ▼                               ▼
┌─────────────────────┐         ┌──────────────────────┐
│      OpsAction      │◀──S/U──│       Alerting        │
│   (scale/exec/etc)   │         │   (rules/alerts)     │
└─────────┬───────────┘         └──────────────────────┘
          │
          ▼
┌─────────────────────┐         ┌──────────────────────┐
│     AuditLog        │◀──EVT──│    All Contexts       │
│   (immutable trail)  │         │                       │
└─────────┬───────────┘         └──────────────────────┘
          │
          ▼
┌─────────────────────┐         ┌──────────────────────┐
│      Residency      │──S/U──▶│  AuditLog, Board,    │
│   (data compliance)  │         │  Assignment, Ops     │
└─────────────────────┘         └──────────────────────┘

Key:
S/K = Shared Kernel    S/U = Supplier → Customer
C/S = Customer ← Supplier    EVT = Domain Event / Event-Driven
```

---

## 3. Complete Event Catalog

| ID | Event Name | Owner Context | Consumers | Payload Sketch |
|----|-----------|--------------|-----------|----------------|
| EVT-001 | `clusterconnect.ClusterConnected` | ClusterConnect | ResourceSync, BoardEngine, AuditLog | `{clusterId, name, provider, region, k8sVersion, connectedAt}` |
| EVT-002 | `clusterconnect.ClusterDisconnected` | ClusterConnect | ResourceSync, BoardEngine, AuditLog, Alerting | `{clusterId, name, lastSeenAt, reason}` |
| EVT-003 | `clusterconnect.ClusterHealthDegraded` | ClusterConnect | BoardEngine, Alerting | `{clusterId, missedHeartbeats, lastSuccessfulPing}` |
| EVT-004 | `resourcesync.ResourceDiscovered` | ResourceSync | BoardEngine, Monitor | `{clusterId, resourceType, resourceName, namespace, uid, rawStatus}` |
| EVT-005 | `resourcesync.ResourceStateChanged` | ResourceSync | BoardEngine, Monitor, Alerting | `{clusterId, resourceType, resourceName, namespace, oldStatus, newStatus, changedFields[]}` |
| EVT-006 | `boardengine.ColumnDefinitionCreated` | BoardEngine | AuditLog | `{boardId, columnId, columnType, columnName, mappingExpression}` |
| EVT-007 | `boardengine.ColumnValueUpdated` | BoardEngine | UI (WebSocket broadcast) | `{boardId, itemId, columnId, newValue, computedAt}` |
| EVT-008 | `boardengine.GroupReorganized` | BoardEngine | AuditLog | `{boardId, groupByField, previousGroupBy, reorganizedBy}` |
| EVT-009 | `boardengine.ViewSwitched` | BoardEngine | AuditLog, UI | `{boardId, fromView, toView, switchedBy}` |
| EVT-010 | `ops.ScaleInitiated` | OpsAction | AuditLog | `{actionId, resourceType, resourceName, namespace, clusterId, currentReplicas, targetReplicas, requestedBy}` |
| EVT-011 | `ops.ScaleCompleted` | OpsAction | BoardEngine, AuditLog | `{actionId, resourceName, namespace, clusterId, previousReplicas, newReplicas, durationMs, status}` |
| EVT-012 | `ops.PodRestartInitiated` | OpsAction | AuditLog, Alerting | `{actionId, podName, namespace, clusterId, requestedBy, restartStrategy}` |
| EVT-013 | `ops.PodLogsRequested` | OpsAction | AuditLog | `{sessionId, podName, namespace, clusterId, containerName, requestedBy, filterSeverity}` |
| EVT-014 | `ops.ResourceDeleted` | OpsAction | ResourceSync, BoardEngine, AuditLog | `{actionId, resourceType, resourceName, namespace, clusterId, requestedBy, uid}` |
| EVT-015 | `ops.ContainerExecInitiated` | OpsAction | AuditLog | `{sessionId, podName, namespace, clusterId, containerName, requestedBy, startedAt}` |
| EVT-016 | `ops.ContainerExecEnded` | OpsAction | AuditLog | `{sessionId, endedAt, exitCode, bytesTransferred}` |
| EVT-017 | `monitor.HealthColumnBreach` | Monitor | Alerting, BoardEngine | `{boardId, itemId, columnId, expression, currentValue, breachedAt}` |
| EVT-018 | `sync.WebSocketConnected` | ResourceSync | BoardEngine (session mgmt) | `{sessionId, clientId, boardId, connectedAt, clusterIds[]}` |
| EVT-019 | `sync.WebSocketDisconnected` | ResourceSync | BoardEngine (session mgmt) | `{sessionId, clientId, disconnectedAt, reason}` |
| EVT-020 | `sync.WebSocketReconnected` | ResourceSync | BoardEngine (delta sync) | `{sessionId, clientId, missedEvents[], resumedAt}` |
| EVT-021 | `assignment.ItemAssigned` | BoardEngine | AuditLog, Alerting | `{boardId, itemId, assignee, assignedBy, assignedAt}` |
| EVT-022 | `assignment.AssignmentChanged` | BoardEngine | AuditLog, Alerting | `{boardId, itemId, previousAssignee, newAssignee, changedBy}` |
| EVT-023 | `auditlog.ActivityRecorded` | AuditLog | AuditLog (persistence) | `{entryId, timestamp, actor, action, target, oldValue, newValue, clusterId, region}` |
| EVT-024 | `residency.DataResidencyPolicyUpdated` | Residency | All storage contexts | `{updatedBy, oldAllowedRegions[], newAllowedRegions[], updatedAt}` |
| EVT-025 | `residency.DataResidencyViolation` | Residency | Alerting, AuditLog | `{attemptedRegion, dataType, dataSize, sourceContext, blockedAt}` |
| EVT-026 | `accessgovernance.RoleAssigned` | AccessGovernance | AuditLog | `{boardId, userId, role, assignedBy, assignedAt}` |
| EVT-027 | `accessgovernance.AccessDenied` | AccessGovernance | AuditLog, Alerting | `{userId, action, target, role, reason, attemptedAt}` |
| EVT-028 | `alerting.AlertRuleCreated` | Alerting | AuditLog, BoardEngine | `{boardId, ruleId, columnId, condition, severity, notificationChannels[], createdBy}` |
| EVT-029 | `alerting.ResourceDegradedAlert` | Alerting | Notification service, AuditLog | `{alertId, ruleId, resourceName, namespace, clusterId, severity, condition, breachedValue, firedAt}` |
| EVT-030 | `alerting.CertificateExpiryWarning` | Alerting | AuditLog, Notification service | `{secretName, namespace, clusterId, ingressNames[], daysUntilExpiry, issuer}` |
| EVT-031 | `alerting.NodePressureAlert` | Alerting | AuditLog, Notification service | `{nodeName, clusterId, pressureType(Disk/Memory/PID), conditionValue, firedAt}` |

---

## 4. Multi-Cloud & Data Residency Implementation Strategy

**Principle:** Data storage regions are globally configurable per deployment. The `Residency` context acts as an enforcement layer between all persistence operations and the underlying storage infrastructure.

**Storage Routing Logic:**
1. Each domain event carries a `region` tag from the source cluster.
2. The `Residency` guard checks the tag against the allowed region list before persisting.
3. If the region is disallowed, the event is:
   a. Dropped (for non-critical data like column value history), OR
   b. Re-routed to the nearest allowed region with a `reroutedFrom` annotation (for audit logs), OR
   c. Rejected, triggering a `DataResidencyViolation` event (for compliance-sensitive data).

**Latency Consideration:**
- Board operations targeting clusters in different regions experience added latency (estimated 50–200ms per inter-region hop).
- The WebSocket sync path is optimized: frontend connects to the nearest edge, which proxies to the cluster's region.
- The architecture supports a read-from-local, write-to-primary pattern for cross-region board configurations.

---

## 5. Ambiguities & Flags

| # | Issue | Severity | Recommendation |
|---|-------|----------|---------------|
| 1 | Requirements do not specify whether the board data should be persisted in a database or reconstructed from live K8s API on every request. | **High** | Recommend a hybrid: an internal database stores column configurations, group definitions, alert rules, and assignments; resource state is fetched live from K8s API and cached in-memory with TTL. |
| 2 | `Secret` resources contain sensitive data; requirements say they should appear as items but don't address masking. | **High** | Add requirement: Secrets column values should be masked by default with a toggle for users who have explicit `secrets-read` permission. |
| 3 | No mention of pagination or virtualization for boards with 1000+ items. | **Medium** | Must implement virtual scrolling + server-side pagination. monday.com handles 10K+ rows via lazy rendering. |
| 4 | Cross-cluster operations (e.g., scaling the same Deployment across 3 clusters) are implied but not explicitly described. | **Medium** | Add a follow-up story for "bulk operations across clusters." |
| 5 | No SLA/SLO targets defined for WebSocket latency or sync freshness. | **Medium** | Recommend documenting: p99 sync latency < 3s, heartbeat interval 30s, full resync every 60s. |
