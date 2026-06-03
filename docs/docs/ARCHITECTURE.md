# Rufkis SRE Platform — Architecture

## System Overview

The Rufkis SRE Platform is built on a **local-first, cloud-synced** architecture. The workspace runs in the browser (or Electron shell) with IndexedDB/SQLite local storage, CRDT-based conflict resolution, and P2P sync via WebRTC. The cloud backend provides persistent storage, advanced analytics, and integrations with external systems.

---

## High-Level Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                              SRE Engineers                               │
├──────────────────────────┬───────────────────────────┬───────────────────┤
│    Engineer A (Browser)  │   Engineer B (Browser)    │  Engineer C (CLI) │
│  ┌────────────────────┐  │ ┌────────────────────┐   │ ┌───────────────┐ │
│  │ Workspace Client   │  │ │ Workspace Client   │   │ │ Workspace CLI │ │
│  │ ┌────────────────┐ │  │ │ ┌────────────────┐ │   │ └───────┬───────┘ │
│  │ │ Local Store    │ │  │ │ │ Local Store    │ │   │         │         │
│  │ │ (IndexedDB)    │◄─┼──┼─┼─┤ (IndexedDB)    │◄─┼───┼─────────┼─────────┘
│  │ │ CRDT (Y.js)    │ │  │ │ │ CRDT (Y.js)    │ │   │         │
│  │ └────────────────┘ │  │ │ └────────────────┘ │   │         │
│  │         │           │  │ │         │           │   │         │
│  │    ┌────┴────┐      │  │ │    ┌────┴────┐     │   │         │
│  │    │WebRTC   │◄─────┼──┼─┼────┤WebRTC   │     │   │         │
│  │    │P2P Sync │      │  │ │    │P2P Sync │     │   │         │
│  │    └─────────┘      │  │ │    └─────────┘     │   │         │
│  │         │           │  │ │         │           │   │         │
│  │    ┌────┴────┐      │  │ │    ┌────┴────┐     │   │         │
│  │    │Cloud    │◄─────┼──┼─┼────┤Cloud    │◄────┼───┼─────────┘
│  │    │Sync     │      │  │ │    │Sync     │     │   │         │
│  │    └─────────┘      │  │ │    └─────────┘     │   │         │
│  └────────────────────┘  │ └────────────────────┘   │         │
└──────────────────────────┴───────────────────────────┴─────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                         Cloud Backend                                    │
│                                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐ │
│  │  API Gateway  │  │  Event Bus   │  │  WebSocket   │  │  Auth Service│ │
│  │  (Kong/Envoy) │  │  (Kafka)     │  │  Server      │  │  (OAuth2)    │ │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘ │
│         │                 │                 │                 │         │
│         ▼                 ▼                 ▼                 ▼         │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                    Core Services Layer                           │   │
│  │                                                                  │   │
│  │  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐      │   │
│  │  │  GitOps Engine  │  │  FinOps Engine │  │  Triage Agent  │      │   │
│  │  │ ┌────────────┐ │  │ ┌────────────┐ │  │ ┌────────────┐ │      │   │
│  │  │ │Remediation │ │  │ │Anomaly Det.│ │  │ │Classifier  │ │      │   │
│  │  │ │Workflow    │ │  │ │(Z-score)   │ │  │ │(LLM)       │ │      │   │
│  │  │ ├────────────┤ │  │ ├────────────┤ │  │ ├────────────┤ │      │   │
│  │  │ │PR Creator  │ │  │ │Optimization│ │  │ │RCA Engine  │ │      │   │
│  │  │ │(Git API)   │ │  │ │Analyzer    │ │  │ ├────────────┤ │      │   │
│  │  │ ├────────────┤ │  │ ├────────────┤ │  │ │Escalation  │ │      │   │
│  │  │ │Runbook     │ │  │ │Showback    │ │  │ │Engine      │ │      │   │
│  │  │ │Registry    │ │  │ │Generator   │ │  │ └────────────┘ │      │   │
│  │  │ ├────────────┤ │  │ ├────────────┤ │  └────────────────┘      │   │
│  │  │ │Policy Eval │ │  │ │Trade-off   │ │                          │   │
│  │  │ │(OPA/Rego)  │ │  │ │Analyzer    │ │                          │   │
│  │  │ └────────────┘ │  │ └────────────┘ │                          │   │
│  │  └────────────────┘  └────────────────┘                          │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                    │                                    │
│                                    ▼                                    │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                    Data Layer                                     │   │
│  │                                                                  │   │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌────────────┐ │   │
│  │  │PostgreSQL  │  │  Redis     │  │  S3/Blob   │  │  Git Repos │ │   │
│  │  │(Primary)   │  │  (Cache)   │  │  (Artifacts)│  │  (Runbooks)│ │   │
│  │  └────────────┘  └────────────┘  └────────────┘  └────────────┘ │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                    │                                    │
│                                    ▼                                    │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                    External Integrations                          │   │
│  │                                                                  │   │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────┐ │   │
│  │  │AWS/GCP   │ │GitHub/   │ │PagerDuty │ │Prometheus│ │Slack   │ │   │
│  │  │/Azure    │ │GitLab/BB │ │OpsGenie  │ │Datadog   │ │Email   │ │   │
│  │  └──────────┘ └──────────┘ └──────────┘ └──────────┘ └────────┘ │   │
│  └──────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Component Details

### 1. Local-First Workspace

| Component | Technology | Purpose |
|-----------|------------|---------|
| **Local Store** | IndexedDB / SQLite | Offline-first data persistence in the browser |
| **CRDT Engine** | Y.js | Conflict-free replicated data types for concurrent editing |
| **P2P Sync** | WebRTC | Direct browser-to-browser sync for real-time collaboration |
| **Cloud Sync** | WebSocket + REST | Background sync to cloud backend with priority ordering |
| **Dashboard UI** | React + TypeScript | Offline-capable SRE dashboard with connectivity awareness |
| **Runbook Editor** | Monaco Editor + YAML validation | Local-first YAML runbook authoring |

### 2. GitOps Engine

| Component | Technology | Purpose |
|-----------|------------|---------|
| **Remediation Workflow** | Node.js | Orchestrates incident-to-runbook mapping and PR creation |
| **Git Provider Abstraction** | libgit2 + REST APIs | GitHub, GitLab, Bitbucket integration |
| **Runbook Registry** | PostgreSQL + Git | Queryable index of all runbooks with version history |
| **Policy Engine** | OPA / Rego | Policy-as-Code evaluation of remediation PRs |
| **PR Templating** | Handlebars/Mustache | Renders runbook changes as Git diffs |

### 3. FinOps Engine

| Component | Technology | Purpose |
|-----------|------------|---------|
| **Cost Telemetry Ingestion** | Python + Provider SDKs | AWS Cost Explorer, GCP Billing API, Azure Cost Management |
| **Anomaly Detection** | Python + pandas/scipy | Rolling window statistics, z-score-based anomaly detection |
| **Optimization Analyzer** | Python + Provider APIs | Right-sizing, RI/spot recommendations, storage tiering |
| **ROI Calculator** | Python | Projects savings over 30/60/90-day periods |
| **Showback Generator** | Python + Jinja2 | Monthly cost allocation reports per team per service |

### 4. Triage Agent

| Component | Technology | Purpose |
|-----------|------------|---------|
| **Alert Ingestion** | Node.js + Webhook | Receives alerts from Prometheus, Datadog, Grafana, etc. |
| **Severity Classifier** | LLM (GPT-4/Claude) + Heuristics | P0-P4 classification with confidence scoring |
| **RCA Engine** | LLM + OpenTelemetry + Git | Multi-source root cause analysis |
| **Runbook Matcher** | Embedding similarity | Matches incidents to runbooks with >90% confidence |
| **Escalation Engine** | Rule-based + OPA | Multi-tier escalation with paging integration |

---

## Data Flow

### Incident Lifecycle

```
1. Alert Arrives (Prometheus/DataDog/etc.)
       │
       ▼
2. Triage Agent Classifies
   ├── Severity (P0-P4) + Confidence
   ├── Team Assignment
   └── Suggested Runbooks
       │
       ▼
3. [If confidence > 90% AND automatable runbook available]
   ├── Self-Healing Agent runs Dry-Run
   │   └── Creates GitOps PR
   └── [If P0 OR self-healing failure OR low confidence]
       └── Escalation Engine pages on-call
           │
           ▼
4. Remediation PR is reviewed & merged
       │
       ▼
5. Audit trail recorded (Git history + metadata)
       │
       ▼
6. Incident resolved / Rollback if needed
```

### Cost Data Flow

```
1. Cloud Provider APIs (AWS Cost Explorer, GCP Billing, Azure Cost Mgmt)
       │
       ▼
2. Cost Telemetry Ingestion Pipeline
   ├── Normalize per-provider data
   ├── Tag allocation (team, service, environment)
   └── Store in PostgreSQL time-series
       │
       ▼
3. [Scheduled / On-Demand]
   ├── Anomaly Detection Scan
   │   └── Alert if z-score > threshold
   ├── Optimization Scan
   │   └── Generate recommendations with ROI
   └── Monthly Showback Generation
       └── Distribute reports to teams
```

### Sync Data Flow

```
1. Local Change Made (offline or online)
       │
       ▼
2. CRDT Operation Stored Locally
   ├── Y.js document updated
   └── Change queued for sync
       │
       ▼
3. [If P2P peers online]
   ├── WebRTC data channel sends CRDT ops
   └── Peers merge changes locally
       │
       ▼
4. [If cloud connectivity available]
   ├── Priority queue processed
   │   ├── Incident updates (priority 1)
   │   ├── Runbook changes (priority 2)
   │   └── Config changes (priority 3)
   ├── Chunked upload with retry
   └── Cloud merges with conflict resolution
       │
       ▼
5. Sync token updated for next incremental sync
```

---

## Security Architecture

### Authentication & Authorization

- **API Tokens**: Bearer tokens scoped to workspace and capabilities
- **OAuth2**: For cloud provider integrations (AWS, GCP, Azure)
- **Git Auth**: Personal Access Tokens for Git provider operations

### Data Encryption

| Layer | Encryption |
|-------|------------|
| **In Transit** | TLS 1.3 for all API and WebSocket connections |
| **At Rest (Cloud)** | AES-256 for database and blob storage |
| **At Rest (Local)** | IndexedDB encryption via WebCrypto API |
| **P2P** | DTLS-SRTP for WebRTC data channels |

### Audit & Compliance

- All remediation actions are recorded in Git history (immutable)
- Signed commits with GPG for all automated PRs
- Policy-as-Code evaluation recorded per PR
- Audit trail API for compliance queries

---

## Deployment Architecture

### Local Development

```bash
# Start backend services
docker compose up -d
# Access: http://localhost:8080

# Start workspace
npm run workspace:dev
# Access: http://localhost:5173
```

### Production (Kubernetes)

```yaml
# Key services:
# - api-gateway: Kong/Envoy
# - gitops-engine: 2+ replicas
# - finops-engine: 1 replica (stateful)
# - triage-agent: 2+ replicas
# - workspace-sync: 2+ replicas
# - postgres: HA with streaming replication
# - redis: Cluster mode
# - kafka: 3-broker cluster
```

---

## Technology Stack Summary

| Layer | Technology | Justification |
|-------|------------|---------------|
| **Frontend** | React + TypeScript + Vite | Fast dev experience, type safety |
| **Local Storage** | Dexie.js (IndexedDB) + SQL.js | Offline-first with SQL query capability |
| **CRDT** | Y.js | Battle-tested CRDT library, rich text support |
| **P2P** | WebRTC (simple-peer) | Direct browser-to-browser, no relay needed |
| **API Gateway** | Fastify | High throughput, schema validation |
| **GitOps** | isomorphic-git + Octokit | Pure JS Git operations, GitHub API |
| **Policies** | OPA/Rego (via @open-policy-agent) | Industry standard policy engine |
| **FinOps** | Python + pandas + scipy | Rich data analysis ecosystem |
| **Triage/LLM** | LangChain + OpenAI/Anthropic | Flexible LLM orchestration |
| **Database** | PostgreSQL + TimescaleDB | Time-series optimized, reliable |
| **Cache/Queue** | Redis + BullMQ | Job queues for async processing |
| **Event Bus** | Kafka (or NATS for smaller deployments) | Event sourcing and streaming |
| **Sync** | WebSocket + CRDT merge | Real-time + offline support |
| **Observability** | OpenTelemetry + Prometheus + Grafana | Standard SRE observability stack |

---

## Performance Considerations

| Aspect | Target | Strategy |
|--------|--------|----------|
| **Incident -> Classification** | < 5 seconds | LLM with caching + fallback heuristics |
| **RCA Analysis** | < 30 seconds | Parallel context collection, streaming results |
| **PR Creation** | < 10 seconds | Pre-rendered templates, async Git operations |
| **Anomaly Scan (1 provider)** | < 60 seconds | Incremental scanning, cached baselines |
| **P2P Sync Latency** | < 200ms | WebRTC data channels, CRDT incremental ops |
| **Cloud Sync (100 changes)** | < 5 seconds | Chunked uploads, priority queuing |

---

## Related Documents

- [API Reference](API.md)
- [OpenAPI Specification](openapi.yaml)
- [Work Plan](WORK-PLAN.json)
- [GitOps Theme](GITOPS.md)
- [FinOps Theme](FINOPS.md)
- [Triage Theme](TRIAGE.md)
- [Workspace Theme](WORKSPACE.md)
