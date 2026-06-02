

# Rufkis — Domain-Driven Design (DDD) Analysis

> **Application:** Kubernetes Operations Console with monday.com-style UI
> **Status:** Initial Draft — Ambiguities flagged separately

---

## 1. Bounded Contexts

| # | Bounded Context | Ubiquitous Language | Responsibility |
|---|---|---|---|
| **BC-01** | **ClusterManagement** | Cluster, Connection, Kubeconfig, Endpoint, HealthCheck, Status (Connected/Disconnected/Error), Region, ClusterGroup | Connect/disconnect clusters, validate credentials, health-probe loop, cluster lifecycle |
| **BC-02** | **WorkloadOperations** | Deployment, Pod, Service, ConfigMap, Namespace, ReplicaSet, Rollout, Scale, Restart, PodPhase (Running/Pending/Failed/CrashLoopBackOff), DraggableCard | CRUD/operations on K8s resources; translates board actions into K8s API calls |
| **BC-03** | **HealthMonitoring** | Node, NodeCondition, ControlPlane, Component (api-server/scheduler/controller-manager/etcd), UtilizationPercent, Threshold, HealthStatus (Healthy/Degraded/Unreachable), SLI, SLO | Poll/watch cluster health, node conditions, resource metrics; emit threshold alerts |
| **BC-04** | **BoardManagement** | Board, Column, Item, Card, View (Kanban/Timeline/Table), ViewSwitcher, GroupByField, BoardScope (cluster+namespace), ResourceType | Create/edit custom boards; persist view layouts; manage card-to-resource mapping |
| **BC-05** | **Collaboration** | User, Team, Role (Viewer/Editor/Admin), Comment, Thread, @Mention, BoardShare, Permission, Notification, ActivityFeed | User management, permissions, commenting, @mentions, activity timeline |
| **BC-06** | **Notifications** | Notification, Channel (InApp/Email/Slack/PagerDuty), NotificationPreference, Digest, AlertRouting | Route events from any context to users/channels; preference management |
| **BC-07** | **Audit** | AuditLog, Event, Actor, Action, Timestamp, Region, ComplianceMarker | Immutable log of all operations; required for SOC2/ISO27001 compliance |
| **BC-08** | **Identity** | UserProfile, Session, OIDCProvider, SSO, Token, APIKey, RBAC | Authentication via OIDC (Okta/AzureAD); API key management for automation |

---

## 2. Integration Patterns Between Bounded Contexts

```
┌─────────────────────────────────────────────────────────────────────┐
│                        EVENT BUS (Regional Partitioned)             │
│         ┌──────────┐   ┌──────────┐   ┌──────────┐  ┌──────────┐   │
│         │  BC-01   │   │  BC-02   │   │  BC-03   │  │  BC-04   │   │
│         │ClusterMgmt│  │WorkloadOps│  │  Health  │  │  Boards  │   │
│         └────┬─────┘   └────┬─────┘   └────┬─────┘  └────┬─────┘   │
│              │              │              │              │         │
│         ┌────▼──────────────▼──────────────▼──────────────▼─────┐   │
│         │                 BC-06 Notifications                    │   │
│         └────────────────────────┬──────────────────────────────┘   │
│                                  │                                  │
│         ┌────────────────────────▼──────────────────────────────┐   │
│         │                 BC-05 Collaboration                    │   │
│         └────────────────────────┬──────────────────────────────┘   │
│                                  │                                  │
│         ┌────────────────────────▼──────────────────────────────┐   │
│         │                 BC-07 Audit (Event Sourced)            │   │
│         └───────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### Pattern Details

| Context Pair | Pattern | Rationale |
|---|---|---|
| **BC-01 ClusterManagement → BC-02 WorkloadOperations** | **Customer-Supplier** | ClusterManagement provides the cluster connection handle; WorkloadOperations is the customer that needs it. Contract: cluster must be Connected before any workload ops. |
| **BC-02 WorkloadOperations → BC-07 Audit** | **Event-Driven** | Every K8s mutation emits events to Audit. No return calls. |
| **BC-03 HealthMonitoring → BC-06 Notifications** | **Event-Driven with ACL** | Health events are canonical; Notifications uses an Anti-Corruption Layer to map them into channel-specific formats (Slack blocks, PagerDuty payloads, email templates). |
| **BC-04 BoardManagement ↔ BC-02 WorkloadOperations** | **Shared Kernel** | Board items ARE resource references (clusterId+namespace+resourceType+resourceName). Shared interface/types package. Both contexts must upgrade in lockstep on schema changes. ⚠️ High coupling risk. |
| **BC-05 Collaboration → BC-04 BoardManagement** | **Conformist** | Collaboration consumes Board's aggregate IDs (boardId, cardId) without modification. No ACL needed. |
| **BC-08 Identity → All others** | **Open-Host Service (OHS) + Published Language** | Identity exposes an OIDC-conformant /userinfo endpoint and a gRPC `UserService` with token introspection. All contexts consume the published language (JWT claims, User proto). |
| **Multi-Cluster/Region** | **Separate Ways (per region)** | Each cloud region (US, EU) has its own event bus partition. Cross-region events are limited to: user profile updates (anonymized), audit log aggregation (anonymized). Raw K8s events NEVER cross region. |

---

## 3. Ubiquitous Language per Context

### BC-01 ClusterManagement
| Term | Definition |
|---|---|
| **Cluster** | A named, authenticated connection to a Kubernetes API endpoint |
| **Kubeconfig** | Credential bundle (cert + token or OIDC) used for API authentication |
| **Connection** | The lifecycle state machine: `Disconnected → Connecting → Connected | Error → Disconnected` |
| **HealthProbe** | A lightweight API discovery ping (GET /.well-known/openid-configuration or /version) run every 5s |
| **ClusterGroup** | An optional logical grouping of clusters (e.g., "EU-Production", "US-Staging") |

### BC-02 WorkloadOperations
| Term | Definition |
|---|---|
| **ResourceCard** | A visual representation of a K8s resource on a board |
| **CardAction** | A context-menu action (Restart, Scale, Delete, Edit YAML, Logs) available on a card |
| **DraggableOperation** | A K8s mutation triggered by a drag-and-drop on the Kanban board |
| **ResourceSnapshot** | A cached projection of K8s resource state; refreshed via watch/poll |

### BC-04 BoardManagement
| Term | Definition |
|---|---|
| **Board** | A named, user-created surface scoped to (cluster, namespace) showing selected resource types |
| **Column** | A vertical grouping of items; in Table view = field, in Kanban view = status group, in Timeline = time bucket |
| **Item** | A single resource instance (e.g., one Deployment) appearing as a row/card |
| **ViewMode** | One of: `table`, `kanban`, `timeline` |
| **BoardScope** | (clusterId, namespace) — the filter context for board contents |

---

## 4. Complete Event Catalog

### 4.1 ClusterManagement Events (BC-01)

| Event Name | Payload Sketch | Consumers |
|---|---|---|
| `clusters.ClusterConnected` | `{ clusterId, clusterName, endpoint, kubernetesVersion, region, connectedBy, connectedAt }` | WorkloadOps (enable actions), HealthMonitoring (start polling), Audit, Notifications |
| `clusters.ClusterDisconnected` | `{ clusterId, clusterName, region, disconnectedBy, reason, disconnectedAt }` | WorkloadOps (disable actions), HealthMonitoring (stop polling), Audit, Billing (stop metering) |
| `clusters.ClusterConnectionLost` | `{ clusterId, clusterName, lastSeenAt, consecutiveFailures, errorMessage, region }` | WorkloadOps (disable), Notifications (alert), Audit, SLA Tracker |
| `clusters.ClusterReconnected` | `{ clusterId, clusterName, downtimeDuration, reconnectedAt, region }` | WorkloadOps (re-enable), Notifications (resolve alert), Audit, SLA Tracker (stop clock) |

### 4.2 WorkloadOperations Events (BC-02)

| Event Name | Payload Sketch | Consumers |
|---|---|---|
| `workload.DeploymentRolloutRestarted` | `{ clusterId, namespace, deploymentName, triggeredBy, timestamp }` | Audit, Notifications (if followed), BoardManagement (refresh card) |
| `workload.DeploymentRolloutRestartFailed` | `{ clusterId, namespace, deploymentName, errorCode, errorMessage, triggeredBy }` | Audit, Notifications (failure alert) |
| `workload.DeploymentScaled` | `{ clusterId, namespace, deploymentName, oldReplicas, newReplicas, triggeredBy }` | Audit, Notifications, BoardManagement (update card count), HealthMonitoring (re-evaluate thresholds) |
| `workload.ScaleToZeroConfirmed` | `{ clusterId, namespace, deploymentName, oldReplicas, confirmedBy }` | Audit (compliance marker) |
| `workload.PodStatusChanged` | `{ clusterId, namespace, podName, previousPhase, newPhase, restarts, node }` | BoardManagement (reflow kanban card), HealthMonitoring, Notifications (if CrashLoopBackOff) |
| `workload.PodErrorStateDetected` | `{ clusterId, namespace, podName, phase: CrashLoopBackOff|ImagePullBackOff, message, lastLogLine }` | BoardManagement (red border), Notifications (critical), SRE Dashboard |
| `workload.DeploymentZeroReadyReplicasDetected` | `{ clusterId, namespace, deploymentName, desiredReplicas, readyReplicas, severity: 'critical' }` | Notifications (PagerDuty), SRE Incident Dashboard |

### 4.3 HealthMonitoring Events (BC-03)

| Event Name | Payload Sketch | Consumers |
|---|---|---|
| `health.NodeStatusChanged` | `{ clusterId, nodeName, oldStatus, newStatus, conditions[], timestamp }` | BoardManagement (highlight node), Notifications, Audit, Alerts |
| `health.ClusterHealthChanged` | `{ clusterId, oldHealth, newHealth, componentFailures[], timestamp }` | Dashboard (overall badge), Notifications (escalation), SLA Tracker |
| `health.ControlPlaneComponentStatusChanged` | `{ clusterId, component: api-server|scheduler|controller-manager|etcd, status: Up|Down|Degraded, timestamp }` | Dashboard, Notifications, Audit |
| `health.ResourceThresholdBreached` | `{ clusterId, entityType: node|pod, entityName, resourceType: cpu|memory, utilizationPercent, threshold: 85, durationMinutes, timestamp }` | Notifications, BoardManagement (color-change), Audit |

### 4.4 BoardManagement Events (BC-04)

| Event Name | Payload Sketch | Consumers |
|---|---|---|
| `boards.BoardCreated` | `{ boardId, boardName, clusterId, namespace, resourceTypes[], createdBy }` | Audit, Analytics, Collaboration (default share with creator) |
| `boards.BoardDeleted` | `{ boardId, deletedBy }` | Audit, Collaboration (remove shares) |
| `boards.BoardViewChanged` | `{ boardId, previousView, newView: table|kanban|timeline, userId }` | Analytics (UI telemetry) |
| `boards.ResourceColumnToggled` | `{ boardId, resourceType, visible: bool, userId }` | Audit, UI State |
| `boards.BoardItemMoved` | `{ boardId, itemId, fieldChanged, oldValue, newValue, userId }` | WorkloadOperations (if maps to K8s mutation), Audit |

### 4.5 Collaboration Events (BC-05)

| Event Name | Payload Sketch | Consumers |
|---|---|---|
| `collaboration.BoardShared` | `{ boardId, invitedUserId, role, invitedBy }` | Notifications (invite), Audit, Identity (validate user exists) |
| `collaboration.BoardAccessProvisioned` | `{ boardId, userId, role, provisionedAt }` | Notifications (success), Audit |
| `collaboration.CommentAdded` | `{ commentId, boardId, cardId, resourceType, resourceName, body, mentionedUserIds[], authorId }` | Notifications (@mention alerts), Audit, BoardManagement (display on card) |
| `collaboration.UserMentionedInComment` | `{ mentionedUserId, mentionedBy, boardId, cardId, commentId, commentPreview }` | Notifications (in-app + email) |
| `collaboration.UnauthorizedEditAttempted` | `{ userId, targetResource, action, boardId, timestamp }` | Audit (security logging) |

### 4.6 Notifications Events (BC-06)

| Event Name | Payload Sketch | Consumers |
|---|---|---|
| `notifications.NotificationSent` | `{ notificationId, userId, type, channel, title, body, sourceEventId }` | Audit (delivery receipt), Analytics |
| `notifications.NotificationFailed` | `{ notificationId, userId, channel, error, retryCount }` | Audit, SRE (delivery health) |

---

## 5. Multi-Cloud & Data Residency Constraints

> ⚠️ **These constraints MUST be enforced at the event bus and data layer levels.**

| Constraint | Rule | Impacted Events |
|---|---|---|
| **EU Data Residency** | Events from clusters in `region: eu-*` MUST NOT be published to event bus partitions outside the EU | All `clusters.*`, `workload.*`, `health.*` events with `region: eu-*` |
| **US-EU Boundary** | Only anonymized audit events and user notifications may cross the Atlantic; raw K8s API payloads must stay in-region | `collaboration.CommentAdded` (PII in `body`/`mentionedUserIds` → strip or tokenize before cross-region routing) |
| **Health Probe Locality** | Health monitoring agents must be deployed in the same cloud region as the cluster they monitor; centralized cross-region checking is forbidden | `health.*` events must indicate originating region; cross-region health checks would give false latency readings |
| **Kubeconfig Storage** | Credentials must be encrypted at rest using region-local KMS keys (AWS KMS in us-east-1 ≠ AWS KMS in eu-west-1) | ClusterManagement persist operation |
| **Audit Immutability** | Audit logs must be written to region-local, append-only stores with cross-region read replicas (read-only) for compliance officers | All audit events |

---

## 6. User Story → Event Mapping

| Story ID | Title | Primary Events Emitted | Success Criteria |
|---|---|---|---|
| CLUSTERCONNECT-01 | Connect to K8s cluster | `clusters.ClusterConnected` | Cluster list updated, status "Connected" |
| CLUSTERCONNECT-02 | View clusters with status | `clusters.ClusterConnectionLost`, `clusters.ClusterStatusChanged` | 30s probe fail → Disconnected state |
| RESOURCE-01 | View Deployments on board | `workload.DeploymentZeroReadyReplicasDetected` | Red badge on 0-ready deploys |
| RESOURCE-02 | Rollout restart deployment | `workload.DeploymentRolloutRestarted` / `.Failed` | Toast + badge animation |
| RESOURCE-03 | Scale deployment | `workload.DeploymentScaled` / `workload.ScaleToZeroConfirmed` | Card count updates |
| RESOURCE-04 | Pod kanban view | `workload.PodStatusChanged`, `workload.PodErrorStateDetected` | Status columns, red border on errors |
| HEALTH-01 | Cluster health dashboard | `health.NodeStatusChanged`, `health.ClusterHealthChanged`, `health.ControlPlaneComponentStatusChanged` | Red highlight on NotReady node |
| HEALTH-02 | Resource monitoring timeline | `health.ResourceThresholdBreached` | >85% for 5min → alert line on chart |
| BOARD-01 | Create custom boards | `boards.BoardCreated`, `boards.ResourceColumnToggled` | New board with selected resources |
| BOARD-02 | Switch board views | `boards.BoardViewChanged`, `boards.BoardItemMoved` | Kanban/Timeline/Table render correctly |
| COLLAB-01 | Share boards with roles | `collaboration.BoardShared`, `collaboration.BoardAccessProvisioned`, `collaboration.UnauthorizedEditAttempted` | Viewer cannot edit resources |
| COLLAB-02 | Comment on resource cards | `collaboration.CommentAdded`, `collaboration.UserMentionedInComment` | @mention triggers notification with deeplink |
| COLLAB-03 | Real-time notifications | `notifications.NotificationSent` (consumes health, workload, collaboration events) | Bell badge + email (opt-in) |

