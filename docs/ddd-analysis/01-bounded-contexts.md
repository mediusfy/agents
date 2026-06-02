# Rufkis — Bounded Contexts

## Overview
Rufkis is a Kubernetes operations console with a monday.com-style visual board UI. This document defines the bounded contexts identified via Domain-Driven Design.

---

## BC-1: WorkloadView
**Purpose:** Render and manage K8s resources as visual board rows with configurable columns.
**Owns:** Board configuration, column layouts, resource display state.
**Ubiquitous Language:**
- *Board* — A named view displaying K8s resources as rows
- *Row* — Represents a single K8s resource (Pod, Deployment, Service, etc.)
- *Column* — An attribute display field (Name, Status, Namespace, CPU, Memory, Labels, etc.)
- *Column Layout* — The ordered set of columns and their visibility settings for a board
- *Inline Editing* — Directly editing a resource attribute from the board cell
- *Detail Drawer* — A sliding right panel showing full resource info (YAML, Events, Logs, Metrics)
- *Board Grouping* — Collapsing rows under headers by a chosen attribute (e.g., group by Namespace)
- *Layout Type* — Board, Kanban, Timeline, Gantt views
- *Resource Type Header* — Collapsible section grouping resources by Kind (Pod, Deployment, etc.)

**Integration Patterns:**
- **Shared Kernel** with Clusters context: both share the Resource model (Pod, Deployment, Namespace, etc.)
- **Customer-Supplier** to Resources context: requests detailed resource data on drawer open
- **Published Language** to Realtime context: publishes `board.BoardRendered`, `board.ColumnLayoutChanged`
- **Conformist** from Identity context: follows workspace/team permissions for board visibility

**Multi-Cloud Constraints:**
- Boards can be scoped to a specific cluster or be cross-cluster
- Cross-cluster boards must respect data residency — resources from EU clusters cannot be cached in US regions
- Column data for GPU instances must include AWS/GCP/Azure-specific pricing columns separately

---

## BC-2: Resources
**Purpose:** Fetch, cache, and serve detailed Kubernetes resource information.
**Owns:** Resource YAML manifests, events, logs, metrics, conditions.
**Ubiquitous Language:**
- *Resource* — Any K8s API object (Pod, Deployment, Service, ConfigMap, Secret, etc.)
- *Manifest* — The full YAML/JSON definition of a resource
- *Conditions* — Status conditions reported by the resource (Available, Progressing, etc.)
- *Events* — K8s events associated with a resource (Normal/Warning)
- *Container Logs* — Streaming or historical logs from pod containers
- *Resource Metrics* — CPU, memory, network, and disk metrics (from Metrics Server / Prometheus)
- *Resource Diff* — Comparison between current and desired state

**Integration Patterns:**
- **Supplier** to WorkloadView context: provides detailed resource data on demand
- **Anti-Corruption Layer** to Clusters context: translates raw K8s API responses into internal resource models
- **Open-Host Service** via gRPC: exposes `ResourceService` for YAML retrieval, event listing, log streaming

**Multi-Cloud Constraints:**
- Log streaming for pods in EU clusters must stay within EU data boundaries
- Metrics aggregation across clusters must account for different metrics sources (EKS CloudWatch, GKE Cloud Monitoring, Azure Monitor, Prometheus on-prem)

---

## BC-3: Clusters
**Purpose:** Manage cluster registrations, connection status, and multi-cluster operations.
**Owns:** Cluster records, connection state, health probes, cross-cluster queries.
**Ubiquitous Language:**
- *Cluster* — A registered Kubernetes cluster (EKS, GKE, AKS, On-Prem, Generic)
- *Data Residency Zone* — Geographic region for data storage (US-East, US-West, EU-Central, EU-West, AP-Southeast)
- *Provider* — The cloud provider or on-premises deployment type
- *Cluster Health Status* — Green (healthy), Yellow (degraded), Red (unreachable)
- *Connection Mode* — Direct API Access or Agent-based (recommended)
- *Heartbeat* — Periodic signal from agent indicating cluster is alive
- *Cross-Cluster Query* — A query that aggregates resources from multiple clusters

**Integration Patterns:**
- **Shared Kernel** with WorkloadView context: shared Resource model
- **Customer-Supplier** to Agent context: provides cluster registration data for agent installation
- **Conformist** from Identity context: enforces workspace-level cluster access permissions

**Multi-Cloud Constraints:**
- Cluster registration must capture cloud provider, region, and data residency zone
- Cross-cluster queries must respect data sovereignty: query results from EU clusters cannot be stored/processed outside EU
- Network latency between control plane and agents in different regions must be documented as SLA

---

## BC-4: AgentOrchestration
**Purpose:** Deploy, manage, and monitor Rufkis agents running in target clusters.
**Owns:** Agent lifecycle, heartbeat monitoring, upgrade management, state delta pipeline.
**Ubiquitous Language:**
- *Agent* — A lightweight service deployed in the target cluster that watches resources and reports state
- *Heartbeat* — Periodic 15-second signal from agent to console
- *State Delta* — The difference in resource state since last report
- *Watch* — Agent's continuous monitoring of K8s resources
- *Agent Installation Type* — Helm chart, kubectl apply, or Operator
- *Agent Version* — Semantic version of the deployed agent
- *Disconnected* — State when heartbeat is missed for >60 seconds

**Integration Patterns:**
- **Supplier** to Clusters context: provides agent-specific cluster connection details
- **Open-Host Service** via gRPC bi-directional stream: agent-to-console communication
- **Published Language** to Realtime context: publishes `agent.ResourceStateChanged`, `agent.AgentConnected`

**Multi-Cloud Constraints:**
- Agent must support air-gapped clusters (on-prem with no internet access) via proxy configuration
- Agent-to-console communication must use TLS + mTLS for all deployments
- Agent in EU clusters must report only to EU-region control plane (data residency)

---

## BC-5: Automation
**Purpose:** Define and execute automation recipes with triggers, conditions, and actions.
**Owns:** Recipe definitions, trigger evaluation, action execution, cooldown tracking.
**Ubiquitous Language:**
- *Recipe* — A named automation rule with trigger, conditions, and actions
- *Trigger* — The event that starts recipe evaluation (Resource State Change, Metric Threshold, Cron, Webhook, Audit Event)
- *Condition* — Additional criteria that must be met (namespace equals, label matches, value thresholds)
- *Action* — The operation to perform (Scale, Restart, Notify, Create PR, Label, Cordon, Drain)
- *Cooldown* — Time window during which a recipe will not re-trigger for the same resource
- *Recipe Status* — Active, Paused, Disabled, Failed
- *Execution Log* — Record of each recipe execution with result

**Integration Patterns:**
- **Customer** to Resources context: reads resource state for trigger evaluation
- **Customer** to Notifications context: dispatches notifications on action execution
- **Supplier** to GitOpsPR context: triggers PR creation for config changes
- **Published Language** to Audit context: publishes `automation.RecipeActionExecuted`

**Multi-Cloud Constraints:**
- Recipe evaluation must happen in the same region as the cluster to minimize latency
- Cross-cluster recipes must explicitly declare which clusters they operate on
- Cooldown state must use a multi-region distributed cache (e.g., Redis with read-replicas in each zone)

---

## BC-6: GitOpsPR
**Purpose:** Create Pull Requests from console changes and monitor GitOps sync status.
**Owns:** PR creation workflow, drift detection, sync status visualization.
**Ubiquitous Language:**
- *Pull Request* — A Git PR created from a console-initiated change
- *Drift* — Difference between Git-declared state and in-cluster state
- *Sync Status* — Synced, OutOfSync, Unknown
- *Commit SHA* — The Git commit hash of the last synced state
- *Target Repository* — Git repo and path for infrastructure-as-code
- *Base Branch* — The branch to target for PR creation (main, master, etc.)
- *Proposed Change* — The diff between current and desired state

**Integration Patterns:**
- **Supplier** to Automation context: provides PR creation API
- **Conformist** to Identity context: enforces git permissions via user's identity
- **Anti-Corruption Layer** wrapping GitHub/GitLab/Bitbucket APIs

**Multi-Cloud Constraints:**
- Git repository can be self-hosted (on-prem) or cloud-based (GitHub.com, GitLab.com)
- Webhook events from on-prem GitLab must be routable to the Rufkis console

---

## BC-7: Identity & Workspace
**Purpose:** User authentication, workspace management, RBAC, team management.
**Owns:** Users, workspaces, roles, permissions, SSO integration.
**Ubiquitous Language:**
- *Workspace* — A collaborative space for a team with its own boards, clusters, and settings
- *Role* — A set of permissions (Admin, Editor, Viewer, Custom)
- *Permission* — Access to specific actions (create board, edit resource, manage automation)
- *SSO Group Sync* — Synchronizing user groups from the identity provider (Okta, Azure AD, Google Workspace)
- *Invite* — Sending an invitation to join a workspace
- *API Key* — Programmatic access token for automation and CI/CD integration

**Integration Patterns:**
- **Published Language** to all contexts: provides user identity and permissions
- **Supplier** to Audit context: user identity for audit trail
- **Open-Host Service** via OAuth2/OIDC for authentication

**Multi-Cloud Constraints:**
- Must support identity federation across cloud providers (AWS IAM for EKS, GCP IAM for GKE, Azure AD for AKS)
- SAML/OIDC SSO must work with data-residency-aware IdP endpoints (e.g., EU-specific Okta tenant)

---

## BC-8: Notifications
**Purpose:** Configure notification channels and dispatch alerts.
**Owns:** Channel configuration, notification rules, dispatch logic, deduplication.
**Ubiquitous Language:**
- *Channel* — A notification destination (Slack, PagerDuty, Email, Webhook, Microsoft Teams)
- *Notification Rule* — A mapping of event types to channels with severity filters
- *Deduplication* — Combining multiple identical alerts into a single notification
- *Severity* — Critical, Warning, Info
- *Escalation Policy* — Rules for escalating unacknowledged alerts
- *Channel Status* — Verified, Unverified, Failed

**Integration Patterns:**
- **Customer** from Automation context: receives notification dispatch requests
- **Customer** from Resources context: receives resource state change alerts
- **Anti-Corruption Layer** for each external provider (Slack API, PagerDuty API, SendGrid SMTP)

**Multi-Cloud Constraints:**
- PagerDuty/Slack regions must be considered (EU vs US data processing)
- Email delivery must comply with CAN-SPAM/GDPR for user notification preferences

---

## BC-9: FinOps
**Purpose:** Provide cost estimates and resource usage visibility.
**Owns:** Cost calculation models, pricing data, usage aggregation.
**Ubiquitous Language:**
- *Cost Estimate* — Projected monthly cost based on current resource usage
- *Cost Component* — CPU, Memory, Storage, Network (egress)
- *Pricing Data* — Current cloud provider pricing for compute, storage, and network
- *Usage Baseline* — Average resource usage over a time period
- *Spot Instance/Reserved Instance Discount* — Savings from alternative pricing models
- *Namespace-level Cost Allocation* — Cost breakdown by Kubernetes namespace

**Integration Patterns:**
- **Customer** to Resources context: reads resource usage for cost calculations
- **Anti-Corruption Layer** for cloud provider pricing APIs (AWS Pricing API, GCP Cloud Billing, Azure Retail Prices)
- **Supplier** to WorkloadView context: provides cost column data

**Multi-Cloud Constraints:**
- Pricing data must be region-specific (US-East vs EU-Frankfurt have different rates)
- Data transfer costs vary by provider and region — must be calculated per-cluster
- Currency display must respect workspace locale (USD, EUR, GBP, JPY)
- Cost data for EU clusters cannot be sent to US-based analytics services

---

## BC-10: Audit
**Purpose:** Record, store, and query audit trails for all user actions.
**Owns:** Audit events, retention policies, search/export capabilities.
**Ubiquitous Language:**
- *Audit Event* — A record of a user action (who, what, when, where)
- *Action Type* — Create, Read, Update, Delete, Execute, Configure
- *Diff* — The before/after state of a changed resource
- *Retention Policy* — Duration to keep audit logs (default: 90 days)
- *Archival* — Moving old logs to cold storage (S3 Glacier, GCS Archive, Azure Cool Blob)
- *Immutable Log* — An audit event that cannot be modified or deleted

**Integration Patterns:**
- **Published Language** from all contexts: receives audit events
- **Supplier** to WorkloadView context: audit log viewer in UI
- **Conformist** from Identity context: enforces admin-only access to audit logs

**Multi-Cloud Constraints:**
- Audit logs must be stored in the same region as the workspace's data residency zone
- GDPR right-to-deletion requests must be supportable
- Immutable storage must use WORM (Write Once Read Many) compliant storage

---

## BC-11: Realtime (WebSocket)
**Purpose:** Push live resource state updates to connected UI clients.
**Owns:** WebSocket connections, subscription management, event fan-out.
**Ubiquitous Language:**
- *Channel* — A WebSocket channel for real-time updates (per cluster, per board, per resource)
- *Subscription* — A client's interest in receiving updates for a specific set of resources
- *State Delta* — Incremental update vs full state snapshot
- *Heartbeat* — Periodic ping to keep the connection alive
- *Reconnect* — Client re-establishing a dropped WebSocket connection
- *Full State Sync* — Sending complete resource state after reconnection

**Integration Patterns:**
- **Customer** from all contexts: receives events to fan out to clients
- **Published Language** from Agent context: `agent.ResourceStateChanged`
- **Open-Host Service** via WebSocket (WSS) protocol

**Multi-Cloud Constraints:**
- WebSocket connections must be terminated close to the user (edge PoPs)
- Cross-region latency: US user watching EU cluster must use regional relay
- Connection state must be resilient to control plane failover across availability zones

---

## BC-12: Navigation
**Purpose:** Command palette, bookmarks/favorites, sidebar, and global search.
**Owns:** Command registry, bookmark storage, search index, navigation state.
**Ubiquitous Language:**
- *Command* — An action or navigation target accessible from the palette
- *Command Palette* — Overlay UI triggered by Cmd+K for quick actions
- *Bookmark* — A saved reference to a resource, board, or view
- *Favorite* — A bookmarked item shown in the sidebar
- *Global Search* — Full-text search across all clusters, resources, namespaces, and boards
- *Deep Link* — A URL that navigates directly to a specific resource or view

**Integration Patterns:**
- **Customer** to all contexts: indexes commands and bookmarks from all contexts
- **Published Language** to Audit context: `navigation.CommandPaletteActionExecuted`

**Multi-Cloud Constraints:**
- Global search must respect cluster-level permissions — users can only see resources they have access to
- Search index must be sharded by region for multi-region deployments
