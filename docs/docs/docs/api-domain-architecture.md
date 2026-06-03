

# Rufkis SRE Platform — API Domain Architecture

> **Author**: CTO Agent  
> **Status**: Approved  
> **Applies To**: Backend, Frontend, DevOps, SRE Agents

---

## 1. Bounded Contexts (Domains)

| Domain | Theme | Description |
|--------|-------|-------------|
| **GitOps** | GitOps-Native Remediation | Runbook definitions, PR-based remediation, policy-as-code, audit trails |
| **FinOps** | Automated FinOps ROI | Cost anomaly detection, optimization recommendations, showback, trade-off dashboards |
| **Triage** | Autonomous Agent Triage | Incident classification, RCA suggestions, self-healing agents, escalation |
| **Workspace** | Local-First SRE Workspace | Offline dashboard, CRDT sync, P2P workspace collaboration, cloud sync |
| **IAM** | Cross-cutting | Auth, RBAC, API keys, team/service membership |
| **Audit** | Cross-cutting | Immutable audit log, Git-backed trail, event sourcing |

---

## 2. RESTful API Endpoints

Base Path: `/api/v1`

### 2.1 GitOps Domain

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/gitops/runbooks` | List all runbook definitions (filterable by team/service) |
| `POST` | `/gitops/runbooks` | Create a new runbook definition (persisted as YAML in Git) |
| `GET` | `/gitops/runbooks/{id}` | Get a single runbook with current version |
| `PUT` | `/gitops/runbooks/{id}` | Update a runbook (creates Git commit + PR) |
| `DELETE` | `/gitops/runbooks/{id}` | Soft-delete or deprecate a runbook |
| `GET` | `/gitops/runbooks/{id}/versions` | List all Git versions of a runbook |
| `GET` | `/gitops/runbooks/{id}/versions/{sha}` | Get a specific version of a runbook |
| `POST` | `/gitops/runbooks/{id}/execute` | Trigger a runbook execution (creates incident PR) |
| `GET` | `/gitops/executions` | List runbook execution history |
| `GET` | `/gitops/executions/{id}` | Get execution status and logs |
| `POST` | `/gitops/executions/{id}/approve` | Approve a pending runbook execution gate |
| `POST` | `/gitops/executions/{id}/reject` | Reject with reason |
| `GET` | `/gitops/policies` | List all policy-as-code definitions |
| `POST` | `/gitops/policies` | Create a new approval/remediation policy |
| `GET` | `/gitops/policies/{id}` | Get policy definition |
| `PUT` | `/gitops/policies/{id}` | Update policy (Git-versioned) |
| `DELETE` | `/gitops/policies/{id}` | Deprecate a policy |
| `POST` | `/gitops/policies/{id}/evaluate` | Evaluate a policy against a specific incident context |
| `GET` | `/gitops/audit` | List Git commit history (audit trail across all GitOps resources) |
| `GET` | `/gitops/audit/{commit}` | Get detailed diff for a specific commit |

### 2.2 FinOps Domain

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/finops/anomalies` | List active cost anomalies (filterable by region/provider/service) |
| `GET` | `/finops/anomalies/{id}` | Get anomaly details with time-series context |
| `POST` | `/finops/anomalies/{id}/acknowledge` | Acknowledge an anomaly (suppresses alerts) |
| `POST` | `/finops/anomalies/{id}/dismiss` | Dismiss a false-positive anomaly |
| `GET` | `/finops/recommendations` | List optimization recommendations with projected ROI |
| `GET` | `/finops/recommendations/{id}` | Get recommendation details with savings breakdown |
| `POST` | `/finops/recommendations/{id}/apply` | Apply a recommendation (delegates to GitOps runbook) |
| `POST` | `/finops/recommendations/{id}/dismiss` | Dismiss a recommendation |
| `GET` | `/finops/showback/teams` | List teams with showback data |
| `GET` | `/finops/showback/teams/{team}` | Get showback report for a team (time-range filterable) |
| `GET` | `/finops/showback/services` | List services with cost allocation |
| `GET` | `/finops/showback/services/{service}` | Get showback report for a specific service |
| `GET` | `/finops/showback/export` | Export showback data (CSV/JSON) for reporting period |
| `GET` | `/finops/tradeoff` | Get cost vs reliability trade-off dashboard data |
| `GET` | `/finops/tradeoff/services/{service}` | Get detailed trade-off analysis for a service |
| `POST` | `/finops/tradeoff/services/{service}/simulate` | Simulate cost impact of a reliability change |
| `GET` | `/finops/budgets` | List budget definitions |
| `POST` | `/finops/budgets` | Create a budget |
| `GET` | `/finops/budgets/{id}` | Get budget with current spend |
| `PUT` | `/finops/budgets/{id}` | Update budget |
| `GET` | `/finops/budgets/{id}/alerts` | List budget threshold alerts |
| `GET` | `/finops/telemetry/ingest` | *(see Cost Telemetry section)* |

### 2.3 Triage Domain

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/triage/incidents` | List incidents (filterable by severity/status/team) |
| `POST` | `/triage/incidents` | Manually create an incident (via API or alert webhook) |
| `GET` | `/triage/incidents/{id}` | Get incident details |
| `PUT` | `/triage/incidents/{id}` | Update incident metadata |
| `PATCH` | `/triage/incidents/{id}/severity` | Update severity classification |
| `PATCH` | `/triage/incidents/{id}/status` | Transition status (acknowledged→investigating→resolved) |
| `PATCH` | `/triage/incidents/{id}/owner` | Assign/reassign incident owner |
| `POST` | `/triage/incidents/{id}/classify` | Trigger AI re-classification of incident |
| `GET` | `/triage/incidents/{id}/rca` | Get root cause analysis suggestions |
| `POST` | `/triage/incidents/{id}/rca` | Trigger RCA analysis |
| `POST` | `/triage/incidents/{id}/rca/{suggestion}/accept` | Accept a suggested root cause |
| `GET` | `/triage/incidents/{id}/runbooks` | Get recommended runbooks for this incident |
| `POST` | `/triage/incidents/{id}/runbooks/{runbookId}/execute` | Execute a runbook against an incident |
| `GET` | `/triage/incidents/{id}/timeline` | Get incident timeline (events, actions, decisions) |
| `GET` | `/triage/agents` | List autonomous agents and their status |
| `GET` | `/triage/agents/{id}` | Get agent status, capabilities, current tasks |
| `POST` | `/triage/agents/{id}/approve-action` | Human-in-the-loop: approve a pending agent action |
| `POST` | `/triage/agents/{id}/reject-action` | Human-in-the-loop: reject with feedback |
| `GET` | `/triage/escalations` | List active escalation policies |
| `POST` | `/triage/escalations` | Create/modify escalation policy |
| `POST` | `/triage/escalations/{id}/test` | Test escalation flow (simulates incident scenario) |
| `GET` | `/triage/schedules` | List on-call schedules |
| `POST` | `/triage/schedules` | Create/modify on-call schedule |
| `GET` | `/triage/schedules/{id}/override` | Get on-call overrides |
| `POST` | `/triage/schedules/{id}/override` | Create an override |

### 2.4 Workspace Domain

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/workspace/dashboards` | List user's dashboards (local-first aware) |
| `POST` | `/workspace/dashboards` | Create a new dashboard layout |
| `GET` | `/workspace/dashboards/{id}` | Get dashboard layout & widget configuration |
| `PUT` | `/workspace/dashboards/{id}` | Update dashboard layout |
| `DELETE` | `/workspace/dashboards/{id}` | Delete a dashboard |
| `GET` | `/workspace/runbooks` | List locally-authored runbooks (offline-compatible) |
| `POST` | `/workspace/runbooks` | Create a runbook draft locally |
| `PUT` | `/workspace/runbooks/{id}` | Update runbook draft |
| `POST` | `/workspace/runbooks/{id}/publish` | Publish draft → GitOps runbook (creates Git PR) |
| `GET` | `/workspace/runbooks/{id}/versions` | List CRDT version history |
| `GET` | `/workspace/runbooks/{id}/diff/{versionA}...{versionB}` | CRDT-aware diff between versions |
| `GET` | `/workspace/peers` | List connected workspace peers (P2P) |
| `GET` | `/workspace/peers/{id}` | Get peer status & sync state |
| `POST` | `/workspace/sync/force` | Force immediate sync to cloud backend |
| `GET` | `/workspace/sync/status` | Get sync status (pending changes, last sync) |
| `GET` | `/workspace/sync/conflicts` | List unresolved sync conflicts |
| `POST` | `/workspace/sync/conflicts/{id}/resolve` | Resolve a sync conflict with a chosen version |

### 2.5 IAM Domain

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/iam/teams` | List SRE teams |
| `POST` | `/iam/teams` | Create a team |
| `GET` | `/iam/teams/{id}` | Get team details |
| `PUT` | `/iam/teams/{id}` | Update team |
| `GET` | `/iam/teams/{id}/members` | List team members |
| `POST` | `/iam/teams/{id}/members` | Add member to team |
| `DELETE` | `/iam/teams/{id}/members/{userId}` | Remove team member |
| `GET` | `/iam/services` | List services (cost-allocation entities) |
| `POST` | `/iam/services` | Create a service |
| `GET` | `/iam/services/{id}` | Get service details |
| `PUT` | `/iam/services/{id}` | Update service |
| `GET` | `/iam/api-keys` | List API keys |
| `POST` | `/iam/api-keys` | Create API key |
| `DELETE` | `/iam/api-keys/{id}` | Revoke API key |
| `GET` | `/iam/roles` | List RBAC roles |
| `POST` | `/iam/roles` | Create role definition |
| `GET` | `/iam/policies` | List IAM policies |
| `POST` | `/iam/policies` | Create IAM policy binding |

---

## 3. WebSocket Channels

Base Path: `/ws/v1`

| Channel | Purpose | Direction | Auth Required |
|---------|---------|-----------|---------------|
| `/ws/v1/incidents/stream` | Real-time incident updates (creation, severity changes, status transitions) | Server→Client | Yes |
| `/ws/v1/incidents/{id}/events` | Event stream for a single incident (timeline, agent actions, decisions) | Bidirectional | Yes |
| `/ws/v1/finops/anomalies` | Real-time cost anomaly alerts | Server→Client | Yes |
| `/ws/v1/finops/recommendations` | New optimization recommendations pushed live | Server→Client | Yes |
| `/ws/v1/finops/budgets/{id}` | Budget threshold breaches | Server→Client | Yes |
| `/ws/v1/gitops/executions/{id}` | Live runbook execution progress (step logs, approval requests) | Server→Client | Yes |
| `/ws/v1/gitops/policies/evaluate` | Real-time policy evaluation results | Server→Client | Yes |
| `/ws/v1/triage/agents/{id}` | Agent thought-stream and action-progress events | Server→Client | Yes |
| `/ws/v1/triage/escalations` | Escalation lifecycle events | Server→Client | Yes |
| `/ws/v1/workspace/sync` | Sync status and conflict notifications | Bidirectional | Yes (device auth) |
| `/ws/v1/workspace/peers` | P2P peer presence and availability | Bidirectional | Yes (device auth) |
| `/ws/v1/workspace/dashboards/{id}` | Live dashboard widget data updates | Server→Client | Yes |
| `/ws/v1/system/health` | Platform health status & service degradation alerts | Server→Client | Yes |

### WebSocket Message Format

```json
{
  "type": "event_type",
  "version": 1,
  "timestamp": "2025-01-01T00:00:00Z",
  "id": "uuid",
  "payload": { },
  "metadata": {
    "correlation_id": "string",
    "actor": "system|user|agent:{agent_id}",
    "domain": "gitops|finops|triage|workspace"
  }
}
```

---

## 4. Webhook Endpoints (GitOps)

Base Path: `/webhooks/v1`

| Method | Path | Event Source | Description |
|--------|------|-------------|-------------|
| `POST` | `/webhooks/v1/github/push` | GitHub/GitLab push | Triggered on Git push to runbook/policy repository |
| `POST` | `/webhooks/v1/github/pull-request` | GitHub/GitLab PR | PR opened/merged/closed on runbook or policy changes |
| `POST` | `/webhooks/v1/github/pull-request-review` | GitHub/GitLab review | PR review submitted (approval/rejection gates) |
| `POST` | `/webhooks/v1/generic/alert` | Prometheus/Datadog/etc | Generic alert webhook (creates incident) |
| `POST` | `/webhooks/v1/generic/cost` | Cloud provider (AWS/C/GCP) | Cost usage webhook for anomaly detection |
| `POST` | `/webhooks/v1/generic/status` | CI/CD pipeline | Deployment status updates for cost-reliability correlation |

### Webhook Response Contract

All webhooks respond with:
- `202 Accepted` — event enqueued for processing
- `400 Bad Request` — malformed payload
- `401 Unauthorized` — invalid signature/secret

Response body:
```json
{
  "status": "accepted",
  "event_id": "uuid",
  "correlation_id": "string",
  "estimated_processing_ms": 500
}
```

---

## 5. CRDT Sync Protocol Endpoints

Base Path: `/sync/v1`

These endpoints support the local-first architecture with CRDT-based conflict resolution.

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/sync/v1/documents` | Create a new syncable document (runbook, dashboard config) |
| `GET` | `/sync/v1/documents/{id}` | Get document with current CRDT state + version vector |
| `POST` | `/sync/v1/documents/{id}/merge` | Push local CRDT changes and merge with server state |
| `GET` | `/sync/v1/documents/{id}/changes?since={lamport}` | Get changes since a given Lamport timestamp |
| `GET` | `/sync/v1/documents/{id}/state` | Get full CRDT state (for initial sync or P2P handoff) |
| `POST` | `/sync/v1/documents/{id}/ack` | Acknowledge receipt of changes up to a version |
| `GET` | `/sync/v1/peers/{deviceId}/documents` | Get list of documents a peer has (for P2P sync routing) |
| `POST` | `/sync/v1/peers/{deviceId}/offer` | P2P: offer document state to another peer |
| `POST` | `/sync/v1/peers/{deviceId}/answer` | P2P: accept document state from another peer |
| `GET` | `/sync/v1/status` | Get overall sync status: pending, conflicts, last sync per document |
| `GET` | `/sync/v1/conflicts` | List unresolved CRDT conflicts |
| `POST` | `/sync/v1/conflicts/{id}/resolve` | Resolve conflict (accept local/remote/merge) |

### CRDT Merge Payload Format

```json
{
  "document_id": "uuid",
  "device_id": "uuid",
  "lamport_timestamp": 42,
  "operations": [
    {
      "type": "add|update|delete",
      "path": "runbook.steps[3].command",
      "value": "kubectl rollout restart",
      "lamport": 41,
      "id": "operation-uuid"
    }
  ],
  "version_vector": {
    "device-a": 15,
    "device-b": 22,
    "cloud-server": 30
  }
}
```

---

## 6. Policy Evaluation Endpoints

Base Path: `/api/v1`

These endpoints support the GitOps policy-as-code engine.

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/gitops/policies/evaluate` | Evaluate incident context against all active policies; returns pass/fail + required approvals |
| `POST` | `/gitops/policies/{id}/evaluate` | Evaluate against a single policy |
| `POST` | `/gitops/policies/evaluate/batch` | Batch evaluate multiple incident contexts (for bulk processing) |
| `GET` | `/gitops/policies/evaluate/history` | List policy evaluation results |
| `GET` | `/gitops/policies/evaluate/history/{id}` | Get a specific evaluation result with detailed reasons |
| `POST` | `/triage/policies/evaluate` | Evaluate incident against triage classification policies (severity, ownership) |
| `POST` | `/finops/policies/evaluate` | Evaluate cost anomaly against FinOps governance policies |

### Policy Evaluation Request

```json
{
  "policy_id": "uuid (optional, omit for all policies)",
  "context": {
    "domain": "gitops|finops|triage",
    "incident_id": "uuid",
    "resource_type": "deployment|service|budget",
    "resource_id": "string",
    "action": "execute_runbook|apply_recommendation|escalate",
    "actor": "user|agent|system",
    "metadata": {}
  }
}
```

### Policy Evaluation Response

```json
{
  "evaluation_id": "uuid",
  "policy_id": "uuid",
  "result": "pass|fail|require_approval",
  "reasons": ["string"],
  "required_approvals": 2,
  "approvers": ["user-1", "user-2"],
  "evaluation_latency_ms": 45
}
```

---

## 7. Cost Telemetry Ingestion

Base Path: `/ingest/v1/finops`

### Time-Series Ingestion

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/ingest/v1/finops/cost/single` | Ingest a single cost data point |
| `POST` | `/ingest/v1/finops/cost/batch` | Batch ingest cost data (up to 10,000 points) |
| `POST` | `/ingest/v1/finops/cost/stream` | WebSocket upgrade for streaming cost telemetry |
| `POST` | `/ingest/v1/finops/usage/single` | Ingest resource usage data point |
| `POST` | `/ingest/v1/finops/usage/batch` | Batch ingest usage data |
| `GET` | `/ingest/v1/finops/status` | Get ingestion pipeline health and throughput stats |

### Batch Format

```json
{
  "source": "aws|gcp|azure|kubecost|custom",
  "provider_account_id": "string",
  "region": "us-east-1",
  "service": "ec2|rds|s3",
  "resource_id": "i-1234567890abcdef0",
  "team": "sre-platform",
  "points": [
    {
      "timestamp": "2025-01-01T00:00:00Z",
      "cost": 0.42,
      "currency": "USD",
      "usage_quantity": 720,
      "usage_unit": "hours",
      "metadata": {
        "instance_type": "t3.medium",
        "tags": {
          "env": "production",
          "tier": "critical"
        }
      }
    }
  ],
  "client_timestamp": "2025-01-01T00:05:00Z",
  "batch_id": "uuid"
}
```

### Ingestion Protocol

- **HTTP/2** for batch ingestion
- **gRPC streaming** (future) for real-time cost telemetry from cloud agents
- **Content-Encoding: gzip** recommended for batches > 100KB
- Rate limit: 10,000 points/batch, 100 batches/min per source
- Response: `202 Accepted` with `batch_id` for dedup tracking

---

## 8. Cross-Cutting Architectural Constraints

### 8.1 Handler Pattern

All endpoints follow:
- **Router** → **Handler** (thin, parse request + call service) → **Service** (business logic) → **Repository** (data access)

### 8.2 Error Responses

```json
{
  "error": {
    "code": "INSUFFICIENT_APPROVALS",
    "message": "Runbook execution requires 2 approvals, only 1 provided",
    "details": {},
    "request_id": "uuid",
    "timestamp": "2025-01-01T00:00:00Z"
  }
}
```

### 8.3 Pagination

All list endpoints support:
- `?page=1&per_page=50` (offset-based) or `?cursor=base64&limit=50` (cursor-based)
- Response includes `next_cursor`, `total_count`, `page`

### 8.4 Eventing (Transactional Outbox)

All mutation endpoints write to a **transactional outbox** table before responding. The outbox is consumed asynchronously to emit domain events (WebSocket, webhooks, Git commits).

### 8.5 Versioning

- URL path versioning (`/api/v1/...`, `/api/v2/...`)
- Minimum 6-month deprecation window
- Sunset header on deprecated endpoints

---

## 9. Summary: Agent Responsibilities

| Domain | Backend Agent | Frontend Agent | Database Engineer |
|--------|---------------|----------------|-------------------|
| GitOps | Implement runbook CRUD, PR workflow, policy eval | Build runbook editor, PR review UI | GITOPS schemas |
| FinOps | Cost anomaly engine, showback calc, trade-off sims | Build cost dashboards, ROI visualizations | FINOPS schemas |
| Triage | Agent orchestration, classification, escalation | Incident workspace, agent activity feed | TRIAGE schemas |
| Workspace | CRDT sync server, P2P relay, conflict resolution | Offline-first UI, CRDT client logic | WORKSPACE schemas |
| IAM | Auth middleware, RBAC evaluation | Login, team management UI | IAM schemas |
