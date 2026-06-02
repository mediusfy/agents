# Workload Management Domain — RUFKIS-01

## Bounded Context: Workload Management

### Ubiquitous Language

| Term | Definition |
|------|-----------|
| **Workload** | A Kubernetes resource that runs containers (Deployment, StatefulSet, DaemonSet, Job, CronJob). Domain aggregate root. |
| **Inline Detail Sheet** | An expandable UI panel below a workload row that shows workload details without navigating away from the list. Accordion behavior (only one open at a time). |
| **Workload Status** | The lifecycle phase of a workload: Running, Pending, Succeeded, Failed, Unknown. |
| **Workload Type** | The Kubernetes resource kind: Deployment, StatefulSet, DaemonSet, Job, CronJob. |
| **Container Spec** | The container definition within a workload: image, ports, resource requests/limits, env vars, volume mounts. |
| **Workload Event** | A Kubernetes event associated with a workload (Normal/Warning types with reasons and messages). |
| **Workload Manifest** | The full Kubernetes YAML definition of the workload resource. |
| **Region/Residency** | The cloud provider region and data residency classification for the cluster hosting the workload. |

### Domain Entities & Aggregate Roots

```
Workload (Aggregate Root)
  ├── id: WorkloadUID
  ├── name: string
  ├── namespace: string
  ├── type: WorkloadType (enum: Deployment|StatefulSet|DaemonSet|Job|CronJob)
  ├── status: WorkloadStatus (enum: Running|Pending|Succeeded|Failed|Unknown)
  ├── labels: map[string]string
  ├── annotations: map[string]string
  ├── creationTimestamp: datetime
  ├── resourceUsage: ResourceMetrics (value object)
  │     ├── cpu: UsageSeries
  │     └── memory: UsageSeries
  ├── replicas: ReplicaInfo (value object)
  │     ├── desired: int
  │     └── ready: int
  ├── containers: ContainerSpec[] (entity)
  │     ├── name: string
  │     ├── image: string
  │     ├── ports: PortMapping[]
  │     ├── resources: ResourceRequirements
  │     ├── envVars: EnvVar[]
  │     └── volumeMounts: VolumeMount[]
  ├── manifest: WorkloadManifest (value object)
  │     ├── rawYAML: string
  │     └── fetchedAt: datetime
  ├── events: WorkloadEvent[] (entity)
  │     ├── type: EventType (Normal|Warning)
  │     ├── reason: string
  │     ├── message: string
  │     ├── source: string
  │     ├── firstTimestamp: datetime
  │     ├── lastTimestamp: datetime
  │     └── count: int
  ├── region: ClusterRegion (value object)
  │     ├── cloud: string (aws|gcp|azure)
  │     ├── region: string (e.g. eu-west-1)
  │     └── residencyLabel: string (e.g. EU-FR, US-GOV)
  └── accessControl: AccessPolicy (value object)
        ├── allowedRoles: string[]
        └── restrictedFields: string[]
```

### Business Rules

1. **Accordion Constraint**: Only one inline detail sheet may be expanded at any time. Expanding a different row collapses the current one.
2. **Deep Linking**: A `?selected=<workload-uid>` query parameter must be respected on page load to auto-expand the corresponding detail sheet.
3. **Data Residency**: Workload data from restricted regions must be served from region-local API endpoints only. Cross-region proxying is forbidden.
4. **Field Masking**: Fields flagged as `restricted` in the access policy (e.g., internal IPs, secrets in YAML) must be masked when the operator's clearance level is insufficient.
5. **Mutate Authorization**: All delete/restart/scale actions must first pass an authorization check for `workloads.mutate` permission in the target cluster context.
6. **Auto-Refresh**: Expanded detail sheets auto-refresh every 30 seconds when the Overview tab is active. Operators can toggle auto-refresh off.
7. **Real-Time Status**: Workload status changes propagate to the UI within 5 seconds via WebSocket push, with yellow-fade animation on updated rows.
8. **Debounced Search**: Free-text search is debounced at 300ms. Filter state is reflected in URL query parameters for shareable URLs.
9. **Filter Persistence**: Active filters are displayed as removable chips and encoded in the URL for deep linking and browser history navigation.

### Integration Patterns

| Context A | Context B | Pattern | Description |
|-----------|-----------|---------|-------------|
| Workload Management | Cluster API (Kubernetes) | Anti-Corruption Layer | The workload bounded context translates between its own domain model and the raw Kubernetes API responses. |
| Workload Management | Identity & Access Mgmt | Customer-Supplier | Workload Management requests authorization decisions; IAM supplies role/permission checks. |
| Workload Management | Audit Logging | Shared Kernel | Workload action events (delete, scale, restart) are consumed by the audit logging context with a shared event schema. |
| Workload Management | Observability/Metrics | Open-Host Service | Metrics data is served via a dedicated service interface (time-series queries) rather than direct cluster access. |
| Workload Management | Multi-Cloud Gateway | Anti-Corruption Layer | Region-specific routing and data residency enforcement is handled by the gateway, presenting a unified API to the frontend. |

### Domain Events

| Event Name | Owner BC | Consumers | Payload (Sketch) |
|-----------|---------|-----------|------------------|
| `workloads.ClusterWorkloadsPageLoaded` | Workload Management | Frontend UI, Analytics | `{ operatorId, clusterId, page, pageSize, sortBy, filters }` |
| `workloads.WorkloadDetailRequested` | Workload Management | Backend API, Metrics Service | `{ workloadUID, namespace, name, type }` |
| `workloads.WorkloadDetailLoaded` | Workload Management | Frontend UI (Detail Sheet) | `{ workloadUID, spec, status, containers[], conditions[] }` |
| `workloads.WorkloadRowSelected` | Workload Management | Frontend UI, URL Router | `{ workloadUID, previousWorkloadUID? }` |
| `workloads.WorkloadRowDeselected` | Workload Management | Frontend UI, URL Router | `{ workloadUID }` |
| `workloads.DeepLinkResolved` | Workload Management | Frontend UI | `{ workloadUID, source: 'url-param' }` |
| `workloads.WorkloadMetricsRequested` | Workload Management | Metrics Service | `{ workloadUID, timeRanges: ['5m','30m','1h'] }` |
| `workloads.WorkloadMetricsLoaded` | Workload Management | Frontend UI (Overview tab) | `{ workloadUID, cpu: [...], memory: [...], replicaInfo }` |
| `workloads.WorkloadMetricsAutoRefresh` | Workload Management | Metrics Service | `{ workloadUID, tab: 'overview' }` |
| `workloads.ContainerSpecRequested` | Workload Management | Backend API | `{ workloadUID }` |
| `workloads.ContainerLogsRequested` | Workload Management | Logging Service | `{ workloadUID, containerName, tailLines: 50 }` |
| `workloads.WorkloadEventsRequested` | Workload Management | Backend API | `{ workloadNamespace, workloadName }` |
| `workloads.WorkloadEventsLoaded` | Workload Management | Frontend UI (Events tab) | `{ workloadUID, events: [...] }` |
| `workloads.WorkloadYAMLRequested` | Workload Management | Backend API (fresh fetch) | `{ workloadUID, namespace, name }` |
| `workloads.WorkloadYAMLCopied` | Workload Management | Analytics | `{ workloadUID }` |
| `workloads.WorkloadYAMLDownloaded` | Workload Management | Analytics | `{ workloadUID, format: 'yaml' }` |
| `workloads.WorkloadFiltersChanged` | Workload Management | Frontend UI, URL Router | `{ search?, namespaces[], types[], statuses[] }` |
| `workloads.WorkloadFiltersCleared` | Workload Management | Frontend UI, URL Router | `{ clearedBy: 'button' }` |
| `workloads.WorkloadDeleteRequested` | Workload Management | Backend API, IAM | `{ workloadUID, namespace, operatorId, clusterId }` |
| `workloads.WorkloadDeleted` | Workload Management | Frontend UI, Audit Log | `{ workloadUID, namespace, operatorId, timestamp }` |
| `workloads.WorkloadRestartRequested` | Workload Management | Backend API, IAM | `{ workloadUID, namespace, operatorId }` |
| `workloads.WorkloadRestarted` | Workload Management | Frontend UI, Audit Log | `{ workloadUID, namespace, operatorId, timestamp }` |
| `workloads.WorkloadScaleRequested` | Workload Management | Backend API, IAM | `{ workloadUID, namespace, newReplicaCount, operatorId }` |
| `workloads.WorkloadScaled` | Workload Management | Frontend UI, Audit Log | `{ workloadUID, namespace, oldCount, newCount, operatorId }` |
| `workloads.WorkloadActionFailed` | Workload Management | Frontend UI, Error Tracking | `{ workloadUID, action: 'delete'|'restart'|'scale', error, reason }` |
| `workloads.WorkloadStatusChanged` | Workload Management | Frontend UI (WebSocket), Notification | `{ workloadUID, oldStatus, newStatus, message }` |
| `workloads.WorkloadWebSocketConnected` | Workload Management | Frontend UI | `{ clusterId, connectedAt }` |
| `workloads.WorkloadWebSocketDisconnected` | Workload Management | Frontend UI, Reconnection Handler | `{ clusterId, disconnectedAt }` |
| `workloads.WorkloadAccessCheckPerformed` | Workload Management | IAM, Audit Log | `{ operatorId, clusterRegion, action, allowed: boolean }` |
| `workloads.WorkloadAccessDenied` | Workload Management | Frontend UI, Audit Log | `{ operatorId, workloadUID, reasonCode: 'RESIDENCY_MISMATCH'|'INSUFFICIENT_ROLE' }` |

### Database Schema (PostgreSQL)

```sql
-- Workload Management bounded context schema

CREATE SCHEMA IF NOT EXISTS workload_mgmt;

-- Aggregate root: workloads
CREATE TABLE workload_mgmt.workloads (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workload_uid    VARCHAR(255) NOT NULL UNIQUE,  -- Kubernetes UID
    name            VARCHAR(253) NOT NULL,
    namespace       VARCHAR(253) NOT NULL,
    type            VARCHAR(50) NOT NULL CHECK (type IN ('Deployment','StatefulSet','DaemonSet','Job','CronJob')),
    status          VARCHAR(20) NOT NULL CHECK (status IN ('Running','Pending','Succeeded','Failed','Unknown')),
    labels          JSONB DEFAULT '{}',
    annotations     JSONB DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    cluster_id      UUID NOT NULL,
    region          VARCHAR(100) NOT NULL,
    residency_label VARCHAR(50),
    
    UNIQUE(namespace, name, cluster_id)
);

-- Value object: replica info (denormalized for performance)
CREATE TABLE workload_mgmt.workload_replicas (
    workload_id     UUID PRIMARY KEY REFERENCES workload_mgmt.workloads(id) ON DELETE CASCADE,
    desired         INT NOT NULL DEFAULT 0,
    ready           INT NOT NULL DEFAULT 0,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Value object: resource metrics (time-series friendly, simplified cache)
CREATE TABLE workload_mgmt.workload_metrics_cache (
    workload_id     UUID NOT NULL REFERENCES workload_mgmt.workloads(id) ON DELETE CASCADE,
    metric_type     VARCHAR(20) NOT NULL CHECK (metric_type IN ('cpu','memory')),
    time_range      VARCHAR(10) NOT NULL CHECK (time_range IN ('5m','30m','1h')),
    series_data     JSONB NOT NULL,  -- [{timestamp, value}, ...]
    cached_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    PRIMARY KEY (workload_id, metric_type, time_range)
);

-- Entity: container specs
CREATE TABLE workload_mgmt.container_specs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workload_id     UUID NOT NULL REFERENCES workload_mgmt.workloads(id) ON DELETE CASCADE,
    name            VARCHAR(253) NOT NULL,
    image           VARCHAR(500) NOT NULL,
    ports           JSONB DEFAULT '[]',  -- [{containerPort, protocol}]
    resource_requests JSONB DEFAULT '{}', -- {cpu, memory}
    resource_limits   JSONB DEFAULT '{}', -- {cpu, memory}
    env_vars        JSONB DEFAULT '[]',  -- [{name, value, sensitive}]
    volume_mounts   JSONB DEFAULT '[]',  -- [{name, mountPath, readOnly}]
    
    UNIQUE(workload_id, name)
);

-- Entity: workload events (cached from K8s)
CREATE TABLE workload_mgmt.workload_events (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workload_id     UUID NOT NULL REFERENCES workload_mgmt.workloads(id) ON DELETE CASCADE,
    event_type      VARCHAR(10) NOT NULL CHECK (event_type IN ('Normal','Warning')),
    reason          VARCHAR(255) NOT NULL,
    message         TEXT,
    source          VARCHAR(255),
    first_seen      TIMESTAMPTZ NOT NULL,
    last_seen       TIMESTAMPTZ NOT NULL,
    count           INT NOT NULL DEFAULT 1,
    
    INDEX idx_workload_events_last_seen (workload_id, last_seen DESC)
);

-- Value object: workload manifest (full YAML)
CREATE TABLE workload_mgmt.workload_manifests (
    workload_id     UUID PRIMARY KEY REFERENCES workload_mgmt.workloads(id) ON DELETE CASCADE,
    raw_yaml        TEXT NOT NULL,
    fetched_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    fetched_by      VARCHAR(255)  -- operator who last triggered fetch
);

-- Access control cache for residency enforcement
CREATE TABLE workload_mgmt.cluster_access_policies (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster_id      UUID NOT NULL,
    region          VARCHAR(100) NOT NULL,
    residency_label VARCHAR(50) NOT NULL,
    allowed_roles   TEXT[] NOT NULL DEFAULT '{}',
    restricted_fields TEXT[] NOT NULL DEFAULT '{}',
    
    UNIQUE(cluster_id, region)
);

-- Indexes for search/filter performance
CREATE INDEX idx_workloads_name_search ON workload_mgmt.workloads USING gin (name gin_trgm_ops);
CREATE INDEX idx_workloads_namespace ON workload_mgmt.workloads(namespace);
CREATE INDEX idx_workloads_type ON workload_mgmt.workloads(type);
CREATE INDEX idx_workloads_status ON workload_mgmt.workloads(status);
CREATE INDEX idx_workloads_cluster ON workload_mgmt.workloads(cluster_id);
CREATE INDEX idx_workloads_residency ON workload_mgmt.workloads(residency_label);
```
