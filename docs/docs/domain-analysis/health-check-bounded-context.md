# Health Check Bounded Context

## Overview
Tiny health-check endpoint responsible for confirming the service is alive and ready to serve traffic. Exposes a single endpoint consumed by load balancers, orchestrators (Kubernetes liveness/readiness probes), and monitoring systems.

## Ubiquitous Language

| Term | Definition |
|------|-----------|
| **Health Check** | An HTTP GET request to `/health` that validates the service is running. |
| **Readiness** | The service is fully initialized and can serve traffic. |
| **Liveness** | The service process is alive and not in a deadlock/crash loop. |

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Returns `{"status":"ok"}` with HTTP 200 when the service is operational. |

## Integration Contracts

- **Shared Kernel**: None. This context is self-contained.
- **Anti-Corruption Layer**: None required. Direct HTTP response.

## Multi-Cloud Constraints

- **Data Residency**: The health endpoint does not read or write any user data, so no data residency constraints apply.
- **Regional Latency**: The health endpoint is lightweight (no DB calls), so regional network latency is negligible (~1–5ms extra across regions). No special handling needed.

## Event Ownership

| Event | Owner |
|-------|-------|
| `health.HealthCheckRequested` | Health Bounded Context |
| `health.HealthCheckSucceeded` | Health Bounded Context |
| `health.HealthCheckFailed` | Health Bounded Context |
