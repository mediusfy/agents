# Architecture Decisions

## Patterns (Established by CTO)

- **Concurrency**: Uses `errgroup` and `signal.NotifyContext` for graceful shutdown.
- **Dependency Injection**: No global state — constructor-based injection only.
- **Handler Pattern**: Thin HTTP handlers delegate all business logic to service layer.
- **Service Layout**: Hexagonal architecture (handlers → services → repositories/ports).
- **Error Disposition**: For event-driven services, errors are dispositioned (logged/metrics/retried), not swallowed.

## Health Check Endpoint (HEALTH-01)

The `/healthz` endpoint is a lightweight, stateless liveness probe. It MUST:
- Live at `/healthz`
- Return HTTP 200 with body `{"status":"ok"}`
- Have `Content-Type: application/json`
- Bypass all middleware other than necessary observability (request ID, minimal logging)
- NOT perform deep dependency checks (database, cache, etc.) — that is a separate `/readyz` concern
