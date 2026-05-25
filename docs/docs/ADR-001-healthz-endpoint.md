# ADR-001: /healthz Liveness Probe Endpoint

## Status
Approved

## Context
Platform operators need a lightweight endpoint for load balancers and orchestrators (Kubernetes, etc.) to confirm the service is alive. This is distinct from a readiness check.

## Decision
Implement `/healthz` returning HTTP 200 with `{"status":"ok"}` and `Content-Type: application/json`.

Key decisions:
1. **No dependency checks** — This is a pure liveness probe. Deep health checks (DB, cache) belong in `/readyz`.
2. **Bypass heavy middleware** — Skip auth, rate limiting, etc. Retain only request ID tracing and minimal logging.
3. **Hardcoded response** — No config or DB lookup. The response byte array should be pre-allocated.
4. **Standard HTTP handler** — Use `net/http` standard handler signature. No framework-specific decorators needed.

## Consequences
- Load balancers get a fast, cheap endpoint.
- Prevents cascading failures — a DB outage won't take down the liveness probe.
- Minimal maintenance surface — effectively zero.
