# CI/CD Architecture

## Overview

This document describes the CI/CD architecture for the SRE Platform, encompassing four microservices:

1. **gitops-service** — Automated incident response via GitOps PRs, runbook validation, policy-as-code
2. **finops-service** — Cloud cost anomaly detection, optimization recommendations, showback reporting
3. **triage-service** — AI-powered incident triage, root cause analysis, self-healing, escalation
4. **workspace-service** — Offline-capable SRE dashboard, CRDT-based runbook authoring, P2P sync

## Pipeline Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    GitHub Actions / GitLab CI                │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │  GitOps   │  │  FinOps   │  │  Triage   │  │ Workspace│   │
│  │  Service  │  │  Service  │  │  Service  │  │ Service  │   │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘   │
│       │              │              │              │         │
│  ┌────▼──────────────▼──────────────▼──────────────▼─────┐  │
│  │               Shared Library Cache                    │  │
│  │         (Go Module Cache, Docker Layer Cache)         │  │
│  └────────────────────────┬─────────────────────────────┘  │
│                           │                                 │
│  ┌────────────────────────▼─────────────────────────────┐  │
│  │           Unified Test & Quality Gate                 │  │
│  │  (lint, unit, integration, e2e, vulnscan, policy)    │  │
│  └────────────────────────┬─────────────────────────────┘  │
│                           │                                 │
│  ┌────────────────────────▼─────────────────────────────┐  │
│  │              Container Build & Push                   │  │
│  │       (docker buildx, cosign sign, sbom gen)         │  │
│  └────────────────────────┬─────────────────────────────┘  │
│                           │                                 │
│  ┌────────────────────────▼─────────────────────────────┐  │
│  │              Deployment (ArgoCD / Helm)               │  │
│  └─────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Trigger Matrix

| Workflow | Trigger | Services |
|----------|---------|----------|
| CI (Build & Test) | push/PR to main | All services |
| GitOps Policy Check | PR labeled `runbook` | gitops-service |
| FinOps Scan | Scheduled (daily) + manual | finops-service |
| Triage Eval | PR created with `incident` label | triage-service |
| Workspace Sync | push to `workspace-sync` branch | workspace-service |
| Release | tag v*.*.* | All services |

## Security Gates

- **SAST**: golangci-lint + govulncheck on every PR
- **DAST**: OWASP ZAP on staging deploy
- **Container Scan**: Trivy on every image build
- **SBOM**: syft generation + cosign attestation on release
- **Policy Check**: OPA/Conftest on all Kubernetes manifests
