# Entity Management - CI/CD Pipeline & Docker Compose

## Overview

This document describes the complete CI/CD pipeline and local development setup for the `entity-management` Go service, supporting all 12 ENTITYMGMT stories.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      GitHub Actions CI/CD                        │
│                                                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌────────────────┐  │
│  │  Lint     │→ │  Unit    │→ │  Build   │→ │  Docker Scan   │  │
│  │  + Vet    │  │  Tests   │  │  Binary  │  │  (Trivy)       │  │
│  └──────────┘  └──────────┘  └──────────┘  └────────────────┘  │
│       │              │              │                            │
│       ▼              ▼              ▼                            │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                       │
│  │  Vuln    │  │  Integ.  │  │  Docker  │                       │
│  │  Scan    │  │  Tests   │  │  Build   │                       │
│  └──────────┘  └──────────┘  └──────────┘                       │
│                                                       ┌─────────┴┐
│                                                       │   CD:    │
│                                                       │  Publish │
│                                                       │  + Deploy│
│                                                       └──────────┘
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Docker Compose (Local Dev)                     │
│                                                                  │
│  ┌──────────────┐  ┌──────────┐  ┌──────────┐  ┌────────────┐  │
│  │ entity-      │→ │ Postgres │  │  NATS    │  │  Redis     │  │
│  │ management   │  │ :5432    │  │  :4222   │  │  :6379     │  │
│  │  :8080       │  └──────────┘  └──────────┘  └────────────┘  │
│  └──────────────┘                                               │
│       │                                                         │
│       ▼                                                         │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  OpenTelemetry Collector (optional, profile: otel)       │    │
│  │  :4317 (gRPC)  :4318 (HTTP)  :8889 (Prometheus)         │    │
│  └──────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

## Files

| File | Purpose |
|------|---------|
| `.github/workflows/entity-management-ci.yml` | Full CI pipeline (lint, test, build, scan) |
| `.github/workflows/entity-management-cd.yml` | CD pipeline (publish, sign, multi-region deploy) |
| `entity-management/docker-compose.yml` | Local dev environment |
| `entity-management/docker-compose.test.yml` | Ephemeral test environment |
| `entity-management/docker-compose.override.yml` | Hot-reload development |
| `entity-management/Dockerfile` | Multi-stage build |
| `entity-management/Makefile` | Developer automation |
| `entity-management/.env.example` | Configuration template |
| `entity-management/config/otel-collector-config.yaml` | OTel collector config |

## Story Coverage

| Story | Description | Pipeline Stage | Docker Service |
|-------|------------|----------------|----------------|
| ENTITYMGMT-01 | Schema definition | unit-tests + integration-tests | postgres |
| ENTITYMGMT-02 | Idempotency (7-day TTL) | unit-tests | postgres |
| ENTITYMGMT-03 | Read observability | unit-tests + CD | nats |
| ENTITYMGMT-04 | Optimistic concurrency | unit-tests + integration-tests | postgres |
| ENTITYMGMT-05 | Soft delete | unit-tests | postgres |
| ENTITYMGMT-06 | Hard delete | unit-tests | postgres |
| ENTITYMGMT-07 | Restore | unit-tests | postgres |
| ENTITYMGMT-08 | Status lifecycle | unit-tests + domain tests | postgres |
| ENTITYMGMT-09 | Cursor pagination | integration-tests | postgres |
| ENTITYMGMT-10 | Transactional outbox | integration-tests + CD | nats |
| ENTITYMGMT-11 | Multi-region data residency | CD (matrix deploy) | env vars |
| ENTITYMGMT-12 | App startup / OTel | build + docker-scan | otel-collector |

## Quick Start

### Prerequisites
- Docker Desktop 4.25+
- Go 1.26+

### Local Development

```bash
# Start all services
cd entity-management
make up

# Run tests
make test

# View logs
make logs

# Stop everything
make down
```

### CI Pipeline

```bash
# Simulate CI locally
make ci-simulate
```

### Environment Variables

Copy `.env.example` to `.env` and customize:

```bash
cp .env.example .env
```

## Security

- **Trivy**: Scans Docker images for CRITICAL/HIGH vulnerabilities
- **govulncheck**: Scans Go dependencies for known CVEs
- **Cosign**: Signs Docker images with keyless signing
- **SBOM**: Generates SPDX SBOM for supply chain transparency
- **Multi-stage build**: Minimizes attack surface by excluding build tools

## Multi-Region Deployment (ENTITYMGMT-11)

The CD pipeline deploys to both `us-east-1` and `eu-west-1` sequentially using a build matrix. Each region gets its own deployment environment with region-specific database and NATS URLs.
