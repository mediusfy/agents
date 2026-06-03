# Rufkis SRE Platform

**The Four-Strategy SRE Platform**: GitOps-native remediation, Automated FinOps ROI, Autonomous agent triage, and a Local-first SRE workspace.

[![GitHub](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![OpenAPI](https://img.shields.io/badge/OpenAPI-3.1-green)](docs/openapi.yaml)

---

## ℹ️ Overview

Rufkis is an open-source Site Reliability Engineering platform that operationalizes four strategic pillars:

| Pillar | Code Prefix | Description |
|--------|-------------|-------------|
| 🛠️ **GitOps-Native Remediation** | `GITOPS-*` | Automated incident response via Pull Requests, declarative runbooks in Git, audit trail via Git history, and policy-as-code approval gates |
| 💰 **Automated FinOps ROI** | `FINOPS-*` | Real-time cloud cost anomaly detection, automated optimization with projected ROI, showback reporting, and cost-vs-reliability trade-off visualization |
| 🤖 **Autonomous Agent Triage** | `TRIAGE-*` | AI-powered severity/ownership classification, automated root cause analysis, self-healing runbook execution, and escalation logic with human-in-the-loop |
| 🖥️ **Local-First SRE Workspace** | `WORKSPACE-*` | Offline-capable dashboard, local-first runbook authoring with CRDTs, P2P sync between team members, and progressive cloud sync |

---

## 📋 16-Story Implementation Plan

The full 16-task plan is documented in [`docs/WORK-PLAN.json`](docs/WORK-PLAN.json). Each story maps to a specific capability within the four strategic themes.

### Quick Reference

| ID | Story | Theme | Priority |
|----|-------|-------|----------|
| GITOPS-01 | Automated Incident Response via GitOps PRs | GitOps | P0 |
| GITOPS-02 | Declarative Runbook Definitions Stored in Git | GitOps | P0 |
| GITOPS-03 | Audit Trail and Rollback via Git History | GitOps | P0 |
| GITOPS-04 | Policy-as-Code for Remediation Approval Gates | GitOps | P1 |
| FINOPS-01 | Real-Time Cloud Cost Anomaly Detection | FinOps | P0 |
| FINOPS-02 | Automated Cost Optimization with Projected ROI | FinOps | P0 |
| FINOPS-03 | Showback/Show-Charge Reporting | FinOps | P1 |
| FINOPS-04 | Cost vs. Reliability Trade-off Dashboard | FinOps | P1 |
| TRIAGE-01 | AI-Powered Incident Triage Classification | Triage | P0 |
| TRIAGE-02 | Automated Root Cause Analysis Suggestions | Triage | P0 |
| TRIAGE-03 | Self-Healing Runbook Execution | Triage | P1 |
| TRIAGE-04 | Escalation Logic with Human-in-the-Loop | Triage | P0 |
| WORKSPACE-01 | Offline-Capable SRE Dashboard | Workspace | P0 |
| WORKSPACE-02 | Local-First Runbook Authoring and Versioning | Workspace | P0 |
| WORKSPACE-03 | P2P Sync Between Team Member Workspaces | Workspace | P1 |
| WORKSPACE-04 | Progressive Sync to Cloud Backend | Workspace | P1 |

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        SRE Engineers / Users                        │
├─────────────────────────────┬───────────────────────────────────────┤
│     Local-First Workspace   │         Cloud Backend                 │
│  ┌───────────────────────┐  │  ┌────────────────────────────────┐  │
│  │ IndexedDB / SQLite    │  │  │ API Gateway                   │  │
│  │ CRDT-based Runbooks   │  │  │ ┌────┐ ┌──────┐ ┌──────────┐ │  │
│  │ P2P Sync (WebRTC)     │◄─┼──┤ │API │ │Event │ │WebSocket │ │  │
│  └───────────────────────┘  │  │ └────┘ │Bus   │ │Server    │ │  │
│                              │  └────────┴──────┴────────────┘ │  │
│                              │  ┌────────────────────────────────┐│
│                              │  │   Core Services                ││
│                              │  │ ┌────────┐ ┌────────┐          ││
│                              │  │ │GitOps  │ │FinOps  │          ││
│                              │  │ │Engine  │ │Engine  │          ││
│                              │  │ ├────────┤ ├────────┤          ││
│                              │  │ │Triage  │ │Worksp. │          ││
│                              │  │ │Agent   │ │Sync    │          ││
│                              │  │ └────────┘ └────────┘          ││
│                              │  └────────────────────────────────┘│
│                              └────────────────────────────────────┘
└─────────────────────────────┴───────────────────────────────────────┘
```

---

## 🚀 Getting Started

### Prerequisites

- Node.js >= 18.x
- Docker & Docker Compose (for local backend)
- Access to a Git provider (GitHub/GitLab/Bitbucket)
- Cloud provider credentials (AWS/GCP/Azure) — for FinOps features

### Quick Start

```bash
# Clone the repository
git clone https://github.com/rufkis/sre-platform.git
cd sre-platform

# Install dependencies
npm install

# Start the backend services
docker compose up -d

# Start the workspace (local-first dashboard)
npm run workspace:dev

# Verify health
curl http://localhost:8080/health
```

---

## 📖 Documentation

| Document | Description |
|----------|-------------|
| [API Reference](docs/API.md) | Complete API documentation for all endpoints |
| [OpenAPI Spec](docs/openapi.yaml) | OpenAPI 3.1 specification |
| [Architecture](docs/ARCHITECTURE.md) | System architecture and data flow |
| [Work Plan](docs/WORK-PLAN.json) | Full 16-story implementation plan |
| [GitOps Theme](docs/GITOPS.md) | GitOps-native remediation deep-dive |
| [FinOps Theme](docs/FINOPS.md) | Automated FinOps ROI deep-dive |
| [Triage Theme](docs/TRIAGE.md) | Autonomous agent triage deep-dive |
| [Workspace Theme](docs/WORKSPACE.md) | Local-first SRE workspace deep-dive |

---

## 🛠️ Core APIs

```http
# GitOps: Create Remediation PR
POST /api/v1/gitops/remediations
Content-Type: application/json

{
  "incident_id": "inc-20260603-001",
  "runbook_id": "rb-database-failover",
  "environment": "production",
  "region": "us-east-1"
}

# FinOps: Detect Cost Anomaly
POST /api/v1/finops/anomalies/scan
Content-Type: application/json

{
  "providers": ["aws", "gcp", "azure"],
  "regions": ["eu-west-1", "us-east-1"],
  "baseline_days": 7
}

# Triage: Classify Incident
POST /api/v1/triage/classify
Content-Type: application/json

{
  "alert_id": "alt-20260603-042",
  "source": "prometheus",
  "title": "High error rate on payment-service",
  "description": "HTTP 500 errors > 5% in last 5 minutes",
  "raw_payload": { ... }
}

# Workspace: Sync Local Changes
POST /api/v1/workspace/sync
Content-Type: application/json

{
  "changes": [
    {
      "type": "runbook_update",
      "runbook_id": "rb-database-failover",
      "crdt_ops": [ ... ]
    }
  ],
  "priority": "high"
}
```

See the full [API Reference](docs/API.md) for all endpoints, request/response schemas, and examples.

---

## 🔧 Technology Stack

| Layer | Technology |
|-------|------------|
| **Frontend (Workspace)** | React, TypeScript, Y.js (CRDT), IndexedDB, WebRTC |
| **Backend API** | Node.js, Express, Fastify |
| **GitOps Engine** | libgit2, GitHub/GitLab APIs, OPA/Rego |
| **FinOps Engine** | Python, pandas, cloud cost APIs (AWS Cost Explorer, GCP Billing, Azure Cost Mgmt) |
| **Triage Agent** | LLM-based classification, OpenTelemetry, Prometheus |
| **Database** | PostgreSQL (primary), Redis (cache/queue), SQLite (local) |
| **Event Bus** | Apache Kafka / NATS |
| **Sync Layer** | CRDT (Y.js), WebRTC, WebSockets |

---

## 📄 License

Apache 2.0 — See [LICENSE](LICENSE)

---

## 🤝 Contributing

We welcome contributions! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

1. Fork the repository
2. Create a feature branch (`git checkout -b feat/your-feature`)
3. Commit your changes (`git commit -m 'feat: add something'`)
4. Push to the branch (`git push origin feat/your-feature`)
5. Open a Pull Request

All PRs follow our GitOps-native workflow and are subject to policy-as-code approval gates.
