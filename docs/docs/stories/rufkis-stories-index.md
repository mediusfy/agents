# Rufkis — User Story Index

> **Product**: Rufkis — Kubernetes Operations Console with monday.com-style UI
> **Last Updated**: 2026-06-02

---

| Story ID | Title | Bounded Context | Priority | Events |
|----------|-------|----------------|----------|--------|
| CLUSTER-01 | Connect K8s Clusters via kubeconfig | Cluster Management | P0 | `ClusterConnected`, `ClusterHealthChanged` |
| CLUSTER-02 | Unified Cross-Cluster Resource View | Cluster Management | P0 | `CrossClusterViewGenerated` |
| BOARD-01 | monday.com-Style Board View | Board Engine | P0 | `BoardRendered`, `CardMoved` |
| BOARD-02 | Customizable Board Column Config | Board Engine | P1 | `ColumnConfigurationChanged` |
| RESOURCE-01 | Create K8s Resources from UI | Resource Catalog | P0 | `ResourceCreated` |
| RESOURCE-02 | Edit Resources with Diff & GitOps PR | Resource Catalog | P0 | `ResourceUpdated`, `PullRequestCreated` |
| RESOURCE-03 | Delete Resources with Cascade & Protection | Resource Catalog | P1 | `ResourceDeleted`, `DeletionBlocked` |
| LIVE-01 | Real-Time WebSocket Status Updates | Live Status | P0 | `ResourceHealthChanged`, `WebSocketConnectionStateChanged` |
| VIS-01 | Timeline/Gantt View | Visualization | P1 | `TimelineViewGenerated` |
| VIS-02 | Calendar View (Scheduled Ops) | Visualization | P2 | `CalendarViewRendered`, `MaintenanceWindowCreated` |
| VIS-03 | Map View (Multi-Cluster Topology) | Visualization | P2 | `MapViewGenerated` |
| VIS-04 | Gallery View (Rich Resource Cards) | Visualization | P2 | `GalleryViewGenerated` |
| SEARCH-01 | Global Search, Filters & Saved Views | Search Engine | P1 | `SearchExecuted`, `SavedViewCreated` |
| ACCESS-01 | RBAC with Team-Based Access Control | Access Control | P0 | `RBACConfigurationChanged`, `PermissionDenied` |
| TEMPLATE-01 | Board Templates & Presets | Template Store | P2 | `TemplateCreated`, `TemplateApplied` |
| GITOPS-01 | GitOps Remediation via PRs | GitOps Bridge | P1 | `PullRequestCreated`, `RemediationCompleted` |
| AGENT-01 | Automation Agent Creation Wizard | Automation Agent | P1 | `AgentCreated`, `AgentActionExecuted`, `AgentRateLimited` |
| ALERT-01 | Priority-Coded Notification System | Alert System | P0 | `AlertTriggered`, `AlertAcknowledged`, `AlertEscalated` |
| AUDIT-01 | Immutable Audit Trail (SOC2/GDPR) | Audit Trail | P0 | `AuditEntryCreated`, `ChainLinkAppended` |

**Priority Definitions:**
- **P0**: Must-have for MVP (cluster connection, board view, resource CRUD, live status, RBAC, alerts, audit)
- **P1**: Core experience (custom columns, GitOps remediation, search, automation agents, timeline)
- **P2**: Enhanced visualization (calendar, map, gallery, templates)
