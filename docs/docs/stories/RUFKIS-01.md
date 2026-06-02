# RUFKIS-01: Workload Management with Inline Detail Sheets

## Overview

This feature enables cluster operators to view, inspect, and manage Kubernetes workloads via an expandable inline detail sheet pattern on the WorkloadsPage. Operators can browse workloads, expand rows to see tabs (Overview, Containers, Events, YAML), and perform quick actions (delete, scale, restart) without leaving the list view.

## User Stories

### WORKLOAD-01: Paginated Workload List
**As a cluster operator, I want to see a paginated list of workloads on the WorkloadsPage so that I can quickly scan all running workloads in the cluster.**

```gherkin
Given the cluster operator navigates to the Workloads page
When the page loads
Then a paginated table of workloads is displayed
And each row shows workload name, namespace, type, status, CPU/Memory usage, and age
And the table supports sorting by any visible column
And the table supports client-side pagination (default 25 items per page)
```

**Events:** `workloads.ClusterWorkloadsPageLoaded`

### WORKLOAD-02: Inline Detail Sheet (Accordion)

**As a cluster operator, I want to click a workload row to expand an inline detail sheet so that I can inspect that workload's configuration, metrics, and events without leaving the list.**

```gherkin
Given the workload list is displayed
When the operator clicks anywhere on a workload row (excluding action buttons)
Then an inline detail sheet expands below the clicked row
And the detail sheet displays tabs: Overview | Containers | Events | YAML
And only one detail sheet is expanded at a time (accordion behavior)
And clicking the same row again collapses the detail sheet
And clicking a different row collapses the current sheet and expands the new one
And the URL updates with a query parameter ?selected=<workload-uid> to support deep linking
```

**Events:** `workloads.WorkloadRowSelected`, `workloads.WorkloadRowDeselected`, `workloads.WorkloadDetailLoaded`, `workloads.DeepLinkResolved`

### WORKLOAD-03: Overview Tab (Metrics & Status)

**As a cluster operator, I want to see the Overview tab in the detail sheet with summary metadata, resource usage charts, and status so that I can quickly assess workload health.**

```gherkin
Given an inline detail sheet is expanded for a selected workload
When the operator clicks the Overview tab
Then the tab displays:
  - Workload metadata (UID, namespace, labels, annotations, creation timestamp)
  - Current status (Running / Pending / Succeeded / Failed / Unknown) with a colored badge
  - Resource usage sparkline chart for CPU (last 5m, last 30m, last 1h)
  - Resource usage sparkline chart for Memory (last 5m, last 30m, last 1h)
  - Number of ready replicas vs desired replicas (if applicable)
  - Latest condition message (e.g., 'Available: True, Reason: MinimumReplicasAvailable')
And all data refreshes every 30 seconds automatically
And the operator can manually trigger a refresh via a refresh icon
```

**Events:** `workloads.WorkloadMetricsRequested`, `workloads.WorkloadMetricsLoaded`, `workloads.WorkloadMetricsAutoRefresh`

### WORKLOAD-04: Containers Tab

**As a cluster operator, I want to see the Containers tab in the detail sheet so that I can inspect each container's image, ports, environment variables, and resource limits.**

```gherkin
Given an inline detail sheet is expanded for a selected workload
When the operator clicks the Containers tab
Then a list of containers in the pod spec is displayed
And each container entry shows:
  - Container name
  - Image name and tag
  - Port mappings (container port / protocol)
  - Resource requests (CPU, Memory)
  - Resource limits (CPU, Memory)
  - Environment variables (with reveal/show-hide for sensitive values)
  - Volume mounts
And the operator can click a container row to expand inline container logs (last 50 lines, streaming optional)
```

**Events:** `workloads.ContainerSpecRequested`, `workloads.ContainerLogsRequested`

### WORKLOAD-05: Events Tab

**As a cluster operator, I want to see the Events tab in the detail sheet so that I can troubleshoot workload lifecycle issues.**

```gherkin
Given an inline detail sheet is expanded for a selected workload
When the operator clicks the Events tab
Then a chronological list of Kubernetes events for the workload is displayed
And each event shows: Type (Normal/Warning), Reason, Message, Source, First/Last timestamp, and Count
And events are sorted by last timestamp descending (most recent first)
And the operator can filter events by type (Normal, Warning, All)
And the operator can copy the raw event JSON to clipboard via a button
```

**Events:** `workloads.WorkloadEventsRequested`, `workloads.WorkloadEventsLoaded`

### WORKLOAD-06: YAML Tab

**As a cluster operator, I want to see the YAML tab in the detail sheet so that I can view and copy the full workload manifest.**

```gherkin
Given an inline detail sheet is expanded for a selected workload
When the operator clicks the YAML tab
Then the full Kubernetes manifest (YAML) for the workload is displayed in a read-only code viewer with syntax highlighting
And the operator can copy the YAML to clipboard via a copy button
And the YAML is fetched fresh from the cluster (not from the list response)
And a timestamp of when the YAML was fetched is shown
And there is a 'Download' button to save the YAML as a .yaml file
```

**Events:** `workloads.WorkloadYAMLRequested`, `workloads.WorkloadYAMLCopied`, `workloads.WorkloadYAMLDownloaded`

### WORKLOAD-07: Filter & Search

**As a cluster operator, I want to filter and search workloads by name, namespace, type, and status so that I can quickly find specific workloads in large clusters.**

```gherkin
Given the workload list is displayed
When the operator types in a search box or selects filter criteria
Then the list filters in real-time (debounced 300ms for text search)
And the operator can filter by:
  - Free-text search on workload name (case-insensitive, partial match)
  - Namespace (dropdown, multi-select, populated from cluster namespace list)
  - Workload type (Deployment, StatefulSet, DaemonSet, Job, CronJob — multi-select)
  - Status (Running, Pending, Succeeded, Failed, Unknown — multi-select)
And active filters are displayed as removable chips above the table
And the URL query string updates to reflect active filters
And the operator can clear all filters with a single 'Clear All' button
```

**Events:** `workloads.WorkloadFiltersChanged`, `workloads.WorkloadFiltersCleared`

### WORKLOAD-08: Quick Actions (Delete, Scale, Restart)

**As a cluster operator, I want to perform quick actions (delete, scale, restart) on a workload from the list row actions menu so that I can manage workloads efficiently.**

```gherkin
Given the workload list is displayed
When the operator clicks the actions (⋮) menu on a row
Then a dropdown with the following options is shown:
  - View Details
  - Scale (opens a modal with current replica count, editable)
  - Restart (rollout restart — confirmation dialog)
  - Delete (confirmation dialog with pod eviction options)
  - Edit YAML (shows 'Coming Soon' for now)
When the operator confirms a Delete action
Then a DELETE request is sent to the backend
And the row is removed from the list with a success toast
When the operator confirms a Restart action
Then a rollout restart is triggered via the backend
And a success toast is shown
And the workload status updates within the next refresh cycle
When the operator confirms a Scale action with a new replica count
Then the backend updates the workload's replica count
And a success toast is shown
And the workload's desired replicas count updates in the row immediately
```

**Events:** `workloads.WorkloadDeleteRequested`, `workloads.WorkloadDeleted`, `workloads.WorkloadRestartRequested`, `workloads.WorkloadRestarted`, `workloads.WorkloadScaleRequested`, `workloads.WorkloadScaled`, `workloads.WorkloadActionFailed`

### WORKLOAD-09: Real-Time Status Updates (WebSocket)

**As a cluster operator, I want to see real-time status updates on workload rows (e.g., pod changes, scaling events) without manually refreshing so that I stay informed of cluster changes.**

```gherkin
Given the workload list is displayed
When a workload's status changes (e.g., pod goes CrashLoopBackOff, scale-up completes)
Then the affected row updates in-place within 5 seconds via WebSocket push or polling
And the updated row shows a brief animated highlight (yellow fade) to draw attention
And the detail sheet, if expanded for that workload, refreshes its data automatically
And a non-intrusive toast notification appears: 'Workload nginx-2 status changed to CrashLoopBackOff'
And the operator can disable auto-refresh via a toggle in the page header
```

**Events:** `workloads.WorkloadStatusChanged`, `workloads.WorkloadWebSocketConnected`, `workloads.WorkloadWebSocketDisconnected`

### WORKLOAD-10: Multi-Cluster Data Residency Compliance

**As a system administrator, I want all workload management operations and views to respect multi-cluster data residency constraints so that workloads in restricted regions are not exposed to unauthorized contexts.**

```gherkin
Given the system is configured with multi-cloud data residency rules
When a cluster operator accesses the Workloads page
Then only workloads from clusters the operator has access to are fetched (RBAC enforced at API gateway and backend)
And if the cluster is in a data-residency-restricted region (e.g., EU-FR, US-GOV)
Then workload data is served from the region-local API endpoint, never routed through a cross-region proxy
And the UI displays a 'Region' badge on each workload row showing the cloud region and data residency label
And the detail sheet's YAML tab masks any fields flagged as 'restricted' when the operator's clearance level is insufficient
And all delete/restart/scale actions first pass through an authorization check that validates the operator has the 'workloads.mutate' permission in the target cluster's context
```

**Events:** `workloads.WorkloadAccessCheckPerformed`, `workloads.WorkloadAccessDenied`

## Bounded Context

See [domain/workload-management.md](domain/workload-management.md) for the full DDD analysis including:
- Ubiquitous language definitions
- Domain entities and aggregate root model
- Business rules (accordion, data residency, RBAC, auto-refresh, debounced search)
- Integration patterns with other contexts (Anti-Corruption Layer, Customer-Supplier, Shared Kernel, Open-Host Service)
- Complete domain event catalog with payload sketches and consumer mappings
- PostgreSQL database schema with indexes
