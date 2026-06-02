# Rufkis — Domain-Driven Design: Bounded Contexts & Ubiquitous Language

> **Product**: Rufkis — Kubernetes Operations Console with monday.com-style UI
> **Last Updated**: 2026-06-02

---

## Overview

Rufkis provides a visual, board-based interface (monday.com paradigm) for managing Kubernetes resources across multiple clusters. The system decomposes into **12 bounded contexts** connected via event-driven integration.

---

## Bounded Contexts Map

| # | Bounded Context | Abbrev | Core Concern | Aggregate Root(s) |
|---|----------------|--------|-------------|-------------------|
| 1 | **Cluster Management** | `CLST` | Cluster lifecycle, discovery, health | `Cluster` |
| 2 | **Board Engine** | `BRD` | monday.com-style board/column/card layout engine | `Board`, `Column`, `Card` |
| 3 | **Resource Catalog** | `RSC` | K8s resource CRUD, manifest validation | `ResourceManifest` |
| 4 | **Live Status** | `LIVE` | WebSocket real-time event streaming | `EventStream` |
| 5 | **Visualization** | `VIZ` | Timeline/Gantt, Calendar, Map, Gallery views | `ViewConfig` |
| 6 | **Search Engine** | `SRCH` | Full-text search, structured filters, saved views | `SearchIndex` |
| 7 | **Access Control** | `ACL` | RBAC, teams, permissions, scoped access | `Team`, `Role`, `Policy` |
| 8 | **Template Store** | `TMPL` | Board templates, presets, versioning | `BoardTemplate` |
| 9 | **GitOps Bridge** | `GOPS` | Git repository operations, PR management | `PullRequest` |
| 10 | **Automation Agent** | `AGNT` | Agent lifecycle, trigger evaluation, action execution | `AutomationAgent` |
| 11 | **Alert System** | `ALRT` | Priority-alerting, escalation, multi-channel delivery | `Alert`, `EscalationPolicy` |
| 12 | **Audit Trail** | `AUDT` | Immutable audit logging, chain-of-custody | `AuditEntry` |

---

## 1. Cluster Management (`CLST`)

**Ubiquitous Language:**
- **ClusterConnection** — Encrypted kubeconfig or cloud API token establishing a link to a K8s cluster
- **ClusterDiscovery** — Automatic enumeration of namespaces, nodes, API resources upon connection
- **ClusterHealth** — Status indicator (Connected / Degraded / Offline) determined by periodic API `/version` pings
- **ClusterMetadata** — Tags (region, environment, team, cloudProvider) for filtering and grouping
- **CrossClusterQuery** — Federated request spanning multiple clusters with data residency awareness

**Integration Patterns:**
- → **ResourceCatalog**: Shared Kernel (Cluster ID is the universal identifier across all contexts)
- → **LiveStatus**: Customer-Supplier (Cluster Health changes feed the event stream)
- → **AccessControl**: Shared Kernel (cluster list drives RBAC scope)
- ↔ **AuditTrail**: Event-driven (all cluster mutations emit `AuditEntryCreated`)

---

## 2. Board Engine (`BRD`)

**Ubiquitous Language:**
- **Board** — A logical workspace representing a cluster or namespace view; analogous to a monday.com board
- **Column** — A resource property column (Name, Status, Namespace, Kind, Age, CPU, Memory, Health); configurable types: Text, Status, Numeric, Date, Person, Timeline, Progress, Tags
- **Card** — A visual representation of a single Kubernetes resource on the board
- **CardStatus** — The health/phase of a resource shown as a color-coded badge (Green=Healthy, Yellow=Warning, Red=Critical, Gray=Unknown)
- **ColumnPreset** — A saved column configuration per user or per team
- **BoardReconciliation** — Periodic (15s) validation of board state vs actual K8s cluster state; drift is auto-corrected

**Integration Patterns:**
- **ResourceCatalog**: Conformist (Board Cards are projections of ResourceCatalog resources)
- **LiveStatus**: Customer-Supplier (WebSocket events update card health badges in real-time)
- **TemplateStore**: Shared Kernel (Board configurations can be saved/loaded as templates)
- **SearchEngine**: Open-Host Service (Board exposes query interface for cross-view search)

---

## 3. Resource Catalog (`RSC`)

**Ubiquitous Language:**
- **ResourceManifest** — The full YAML/JSON spec of a K8s resource
- **ResourceKind** — The type of K8s resource (Pod, Deployment, Service, ConfigMap, Secret, Ingress, HPA, Node, Event)
- **ManifestValidation** — Client-side + server-side (K8s admission webhook) validation
- **InlineEditor** — Dual-mode editor (Form mode ↔ YAML editor) with syntax highlighting, auto-complete, and diff preview
- **CascadeDelete** — Recursive deletion including child resources (e.g., Deployment → ReplicaSets → Pods)
- **ProtectedResource** — A resource annotated with `rufkis.io/protected: "true"` that blocks deletion

**Integration Patterns:**
- **BoardEngine**: Conformist (Board Cards are read-only projections)
- **GitOpsBridge**: Customer-Supplier (Resource edits can fork into PRs instead of direct applies)
- **AccessControl**: Shared Kernel (RBAC policies gate all CRUD operations)
- **AuditTrail**: Event-driven (every CRUD operation emits an audit event)

---

## 4. Live Status (`LIVE`)

**Ubiquitous Language:**
- **EventStream** — WebSocket connection delivering real-time status deltas from K8s watch APIs
- **HealthTransition** — A state change (e.g., Running → CrashLoopBackOff) with before/after values
- **WebSocketMultiplexer** — Server-side component that batches events across clusters and delivers at max 60fps
- **EventBuffer** — Server-side buffer retaining the last 60s of events for replay on reconnect
- **ExponentialBackoff** — Client reconnection strategy (1s, 2s, 4s, 8s max)

**Integration Patterns:**
- **BoardEngine**: Customer-Supplier (provides real-time card updates)
- **AlertSystem**: Event-driven (health transitions can trigger alerts)
- **Visualization**: Event-driven (provides data for timeline/gallery views)

---

## 5. Visualization (`VIZ`)

**Ubiquitous Language:**
- **TimelineView** — Gantt-chart layout showing resource lifecycles grouped by kind with zoom (1h–30d)
- **CalendarView** — Monthly/weekly/daily calendar of scheduled ops (CronJobs, HPAs, maintenance windows, cert expirations)
- **MapView** — Geographic world map with cluster markers and inter-cluster latency lines
- **GalleryView** — Masonry/grid layout of rich resource cards with radial health rings
- **ViewPreset** — Saved view configuration with filters, time range, and layout preferences

**Integration Patterns:**
- **BoardEngine**: Conformist (Views are alternative renderings of the same board data)
- **AlertSystem**: Event-driven (Calendar view consumes maintenance windows from AlertSystem)
- **ClusterManagement**: Customer-Supplier (Map view consumes cluster topology data)

---

## 6. Search Engine (`SRCH`)

**Ubiquitous Language:**
- **GlobalSearch** — Unified search bar supporting free-text + structured query syntax
- **StructuredFilter** — Property-based filters: kind=Pod, namespace=production, cpu>500m, memory>1Gi, created<7d
- **SavedView** — A named combination of filters + view type persisted for quick access
- **CrossViewPersistence** — Filters persist when switching between Board/Timeline/Calendar/Map/Gallery views

**Integration Patterns:**
- **BoardEngine**: Shared Kernel (search results link back to board cards)
- **ResourceCatalog**: Open-Host Service (search indexes resource catalog data)

---

## 7. Access Control (`ACL`)

**Ubiquitous Language:**
- **Team** — A group of users with shared permissions (e.g., "Platform Engineering")
- **ScopedPermission** — Fine-grained access: cluster scope, namespace scope, resource kind scope, action scope (view/edit/create/delete)
- **Policy** — A set of rules defining allowed/denied operations
- **PermissionTest** — Dry-run evaluation of a permission set against a hypothetical resource
- **RestrictedValue** — Column values masked as "[Restricted]" for unauthorized users

**Integration Patterns:**
- **ResourceCatalog**: Shared Kernel (access control gates every CRUD)
- **BoardEngine**: Conformist (Board UI hides/shows elements based on permissions)
- **AuditTrail**: Event-driven (PermissionDenied events are audited)

---

## 8. Template Store (`TMPL`)

**Ubiquitous Language:**
- **BoardTemplate** — A reusable blueprint containing column config, default view, filters, color scheme
- **TemplateScope** — Visibility level: personal, team, global
- **TemplateVersion** — Versioned updates to published templates
- **TemplateUpdateBadge** — UI indicator when a board's source template has a newer version

**Integration Patterns:**
- **BoardEngine**: Shared Kernel (templates create new boards with preset configuration)
- **SearchEngine**: Shared Kernel (templates are searchable)

---

## 9. GitOps Bridge (`GOPS`)

**Ubiquitous Language:**
- **GitRepository** — A configured Git repo reference (URL, branch, deployment path)
- **GitBranch** — Feature branch created per remediation (`fix/api-server-rollback-{timestamp}`)
- **PullRequest** — GitHub/GitLab PR with auto-generated title, description, labels, and assignee
- **RemediationAction** — A suggested or executed fix (rollback image, scale replicas, adjust probes, update resources)
- **DiffPreview** — Side-by-side comparison of current spec vs proposed change

**Integration Patterns:**
- **ResourceCatalog**: Customer-Supplier (pulls resource specs for PR generation)
- **AlertSystem**: Event-driven (remediation completion updates alert status)
- **AuditTrail**: Event-driven (all Git operations are audited)

---

## 10. Automation Agent (`AGNT`)

**Ubiquitous Language:**
- **AutomationAgent** — An autonomous operator that watches triggers and executes actions
- **AgentTrigger** — Event-based (health drops to Critical) or time-based (cron schedule)
- **AgentAction** — Executable operation: restart pods, scale replicas, create notification, run kubectl, create GitOps PR
- **CooldownWindow** — Minimum interval between consecutive agent actions (e.g., 15m)
- **RateLimit** — Maximum actions per time window (e.g., 5 per hour)
- **AgentExecutionHistory** — Log of all triggered actions with before/after state

**Integration Patterns:**
- **LiveStatus**: Customer-Supplier (agents watch health events as triggers)
- **AlertSystem**: Event-driven (agent actions can trigger notifications)
- **GitOpsBridge**: Open-Host Service (agents can trigger PR creation)
- **ResourceCatalog**: Shared Kernel (agents perform CRUD on resources)

---

## 11. Alert System (`ALRT`)

**Ubiquitous Language:**
- **AlertPriority** — Severity level: P0 (Critical) through P4 (Info)
- **DeliveryChannel** — Notification destination: PagerDuty, Slack, Email, SMS, In-app toast, Webhook
- **EscalationPolicy** — Multi-tier on-call routing with time-based escalation (15m → next tier)
- **QuietHours** — Configurable time window during which P2-P4 alerts are silenced (override for P0)
- **AlertStatus** — Lifecycle: Triggered → Acknowledged → Resolved (or → Escalated)
- **MaintenanceWindow** — Pre-scheduled period of silenced alerting for planned changes

**Integration Patterns:**
- **ClusterManagement**: Event-driven (cluster health changes → alerts)
- **LiveStatus**: Event-driven (resource health transitions → alerts)
- **AutomationAgent**: Shared Kernel (agent actions can trigger/suppress alerts)
- **Visualization**: Event-driven (Calendar view displays maintenance windows)

---

## 12. Audit Trail (`AUDT`)

**Ubiquitous Language:**
- **AuditEntry** — An immutable record of a single operation with: timestamp, actor, action, resource ref, payload hash, status, geo-location
- **HashChain** — Cryptographic linking of entries (each entry contains SHA256 hash of the previous entry)
- **ChainIntegrity** — Verification mechanism ensuring no entries have been tampered with
- **DataResidencyPolicy** — Rules ensuring audit logs are stored in the region matching the actor's geo-location and target cluster

**Integration Patterns:**
- **All Contexts**: Event-driven (every bounded context publishes AuditEntryCreated)
- **AccessControl**: Shared Kernel (geo-location data is shared with ACL for residency checks)

---

## Integration Summary

| Source Context | Target Context | Pattern | Mechanism |
|---------------|---------------|---------|-----------|
| ClusterManagement | ResourceCatalog | Shared Kernel | Cluster ID |
| ClusterManagement | LiveStatus | Customer-Supplier | Health events → event stream |
| BoardEngine | ResourceCatalog | Conformist | Cards = projections of manifests |
| LiveStatus | BoardEngine | Customer-Supplier | WebSocket health deltas |
| LiveStatus | AlertSystem | Event-driven | Health transitions trigger alerts |
| ResourceCatalog | GitOpsBridge | Customer-Supplier | Edits can fork into PRs |
| ResourceCatalog | BoardEngine | Conformist | Board is read-only projection |
| GitOpsBridge | AlertSystem | Event-driven | PR completion updates alerts |
| AutomationAgent | LiveStatus | Customer-Supplier | Agents watch health events |
| AutomationAgent | ResourceCatalog | Shared Kernel | Agents perform CRUD |
| AutomationAgent | AlertSystem | Event-driven | Agent events → notifications |
| Visualization | BoardEngine | Conformist | Views render same data differently |
| SearchEngine | BoardEngine | Shared Kernel | Results link to board cards |
| AccessControl | ResourceCatalog | Shared Kernel | RBAC gates CRUD |
| AuditTrail | All | Event-driven | Universal audit event consumer |
| TemplateStore | BoardEngine | Shared Kernel | Templates → board instantiation |
| AlertSystem | ClusterManagement | Event-driven | Cluster health → alert evaluation |
| AlertSystem | Visualization | Event-driven | Maintenance windows → Calendar |

---

## Multi-Cloud & Data Residency Constraints

1. **EU Data Residency**: When an operator in the EU manages an `eu-*` cluster, no resource data may leave EU boundaries. The `CrossClusterViewGenerated` event must strip non-EU data from results.
2. **Audit Log Locality**: Audit entries for EU-based operations must be stored in EU-region storage. `audit-trail.AuditEntryCreated` events carry a `geoRegion` field to enforce this routing.
3. **Cluster Metadata**: Cluster metadata (region, cloud provider) must be propagated through all events to enable data residency filtering at the consumer level.
4. **Search Constraints**: Cross-cluster search results must respect data residency rules — results from EU clusters are not cached in non-EU search indexes.
