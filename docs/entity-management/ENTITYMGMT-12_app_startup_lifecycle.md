# ENTITYMGMT-12: Application Startup Lifecycle

**Story:** Application starts with migrations, composition root DI, health checks, and OpenTelemetry observability

**Status:** ✅ Implemented

**Migration:** `ENTITYMGMT-12_000_app_startup_lifecycle`

---

## Overview

This story implements the application startup lifecycle for the Entity Management service. It establishes:

1. **Composition Root DI** — Dependencies wired in a strict order in `pkg/app.go`
2. **Database Migrations** — Schema and entity migrations run at startup
3. **Health Endpoints** — `/healthz` (liveness) and `/readyz` (readiness) on chi router
4. **OpenTelemetry Observability** — Spans, trace attributes, error recording, metrics
5. **App Lifecycle Events** — `entitymanagement.app.started` and `entitymanagement.app.startup_failed`

---

## Architecture

### Dependency Injection Order

The composition root in `pkg/app.go` initializes dependencies in this exact order:

```
 1. Logger (slog.JSONHandler)
 2. Database connection pool (pgxpool) with ping verification
 3. Schema, Entity, Outbox, Idempotency repositories (Postgres adapters)
 4. Database migrations (schema + entity tables)
 5. NATS event bus connection (with noop fallback)
 6. Event publisher adapter (CloudEvents enveloping)
 7. Schema validator (in-memory cache)
 8. Domain service (UnitOfWork, RequestIdempotencyStore)
 9. Application use cases
10. HTTP handlers (chi router)
11. Health endpoints (/healthz, /readyz) registered
```

### Health Check Endpoints

| Endpoint | Method | Description | Status Code |
|----------|--------|-------------|-------------|
| `/healthz` | GET | Liveness probe — always returns 200 | `{"status": "ok"}` |
| `/readyz` | GET | Readiness probe — checks DB ping | `{"status": "ready"}` or 503 |

#### `/healthz` (Liveness)
- Always returns HTTP 200 with `{"status": "ok"}`
- No database dependency — the application is alive if this responds
- Designed for K8s liveness probe

#### `/readyz` (Readiness)
- Pings the database connection pool via `pool.Ping(ctx)`
- If ping succeeds: HTTP 200 with `{"status": "ready"}`
- If ping fails: HTTP 503 with `{"status": "unavailable", "reason": "<error>"}`
- Designed for K8s readiness probe

### OpenTelemetry Observability

Every CRUD operation creates OpenTelemetry spans with:

**Naming convention:** `<package>.Operation`
- `ports.SchemaHTTPHandler.handleDefineSchema`
- `ports.EntityHTTPHandler.handleCreateEntity`
- `postgres.EntityRepository.Save`
- `application.SchemaService.DefineSchema`
- etc.

**Trace attributes:** Populated with:
- `entity_id` — The entity being operated on
- `schema_id` — The schema being operated on
- `version` — The version number (for updates)
- `operation` — The type of operation (create, read, update, delete)
- `status` — The operation result status

**Error recording:** `span.RecordError(err)` on all error paths

**Metrics counters:** Incremented for operation types:
- `entity.crud.operations.total` — Per operation type
- `entity.crud.operations.duration_ms` — Histogram of operation duration
- `entity.repository.queries.total` — Per query type
- `app.startup.duration_ms` — Startup duration histogram
- (Full list in `otel_metrics_config` table)

---

## Database Schema

### `app_startup_events`

Tracks every application startup attempt.

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID PK | Unique startup event ID |
| `service_name` | VARCHAR(255) | Service identity |
| `service_version` | VARCHAR(64) | Semantic version |
| `region` | VARCHAR(64) | Deployment region |
| `hostname` | VARCHAR(512) | OS hostname |
| `pid` | INTEGER | Process ID |
| `deployment_id` | VARCHAR(128) | CI/CD deployment ID |
| `status` | VARCHAR(32) | `started`, `failed`, `running`, `shutdown` |
| `stage` | VARCHAR(64) | Composition root stage |
| `latest_migration_id` | VARCHAR(64) | Latest migration applied |
| `latest_migration_number` | INTEGER | Numeric migration version |
| `error_message` | TEXT | Error details (NULL if success) |
| `error_stage` | VARCHAR(64) | Stage of failure (NULL if success) |
| `startup_started_at` | TIMESTAMPTZ | When startup began |
| `startup_completed_at` | TIMESTAMPTZ | When startup finished |
| `startup_duration_ms` | INTEGER | Duration in milliseconds |
| `shutdown_at` | TIMESTAMPTZ | Graceful shutdown time |
| `shutdown_reason` | VARCHAR(512) | Shutdown reason |
| `outbox_event_id` | TEXT | Linked outbox event |
| `created_at` | TIMESTAMPTZ | Record creation time |
| `updated_at` | TIMESTAMPTZ | Record update time |

### `app_deployments`

Tracks deployment versions per service and region.

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID PK | Unique deployment ID |
| `service_name` | VARCHAR(255) | Service identity |
| `version` | VARCHAR(64) | Semantic version |
| `region` | VARCHAR(64) | Deployment region |
| `zone` | VARCHAR(64) | Data residency zone |
| `deployment_id` | VARCHAR(128) | CI/CD deployment identifier |
| `git_commit` | VARCHAR(64) | Git commit SHA |
| `git_branch` | VARCHAR(255) | Git branch |
| `built_at` | TIMESTAMPTZ | Build timestamp |
| `deployed_by` | VARCHAR(255) | Deployment trigger |
| `deployment_strategy` | VARCHAR(32) | `rolling`, `blue_green`, `canary`, `recreate` |
| `status` | VARCHAR(32) | `active`, `inactive`, `rolled_back`, `failed` |
| `deployed_at` | TIMESTAMPTZ | Deployment time |
| `rolled_back_at` | TIMESTAMPTZ | Rollback time |

### `otel_metrics_config`

Runtime configuration for OpenTelemetry metrics collection.

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID PK | Unique config ID |
| `metric_name` | VARCHAR(255) UNIQUE | Metric identifier |
| `metric_type` | VARCHAR(32) | `counter`, `histogram`, `gauge`, `updown_counter` |
| `metric_description` | TEXT | Human-readable description |
| `metric_unit` | VARCHAR(64) | Unit of measurement |
| `package_scope` | VARCHAR(255) | Package that emits the metric |
| `operation_name` | VARCHAR(255) | Operation name within package |
| `enabled` | BOOLEAN | Whether metric collection is active |
| `sampling_rate` | REAL | Rate (0.0 to 1.0) |
| `aggregation_interval_seconds` | INTEGER | Metric aggregation interval |
| `attribute_dimensions` | JSONB | Attribute labels to record |

---

## Domain Events

### `entitymanagement.app.started`

**Owned by:** EntityManagement context  
**Published when:** Application completes initialization and is ready to serve traffic

**Payload:**
```json
{
  "event_id": "<uuid>",
  "service_name": "entity-management",
  "version": "1.0.0",
  "region": "eu-west-1",
  "migration_id": "ENTITYMGMT-12",
  "migration_version": 12,
  "hostname": "pod-abc-123",
  "pid": 42,
  "deployment_id": "deploy-gha-184729",
  "startup_duration_ms": 3200,
  "uptime_seconds": 3.2,
  "started_at": "<timestamp>"
}
```

**Consumers:**
| Consumer | Purpose |
|----------|---------|
| OrchestratorContext | K8s readiness, deployment health |
| ObservabilityContext | Startup metrics, uptime tracking |

### `entitymanagement.app.startup_failed`

**Owned by:** EntityManagement context  
**Published when:** Application fails to initialize (database, migration, config)

**Payload:**
```json
{
  "event_id": "<uuid>",
  "service_name": "entity-management",
  "error": "connection refused: dial tcp 10.0.0.1:5432: connect: connection refused",
  "stage": "database_connection",
  "service_version": "1.0.0",
  "region": "eu-west-1",
  "hostname": "pod-abc-123",
  "pid": 42,
  "occurred_at": "<timestamp>"
}
```

**Consumers:**
| Consumer | Purpose |
|----------|---------|
| AlertingSystem | Trigger deployment rollback |
| OrchestratorContext | K8s CrashLoop detection |

---

## Database Functions

| Function | Purpose | Gherkin |
|----------|---------|---------|
| `enqueue_app_started_event()` | Enqueues `app.started` outbox event | SCENARIO 1 |
| `enqueue_app_startup_failed_event()` | Enqueues `app.startup_failed` outbox event | SCENARIO 2 |
| `record_app_startup()` | Atomic: insert startup record + enqueue event | SCENARIO 1 |
| `record_app_startup_failure()` | Atomic: insert failure record + enqueue event | SCENARIO 2 |
| `get_latest_successful_startup()` | Returns latest running startup | SCENARIO 3 |
| `get_last_startup_failure()` | Returns latest failure for diagnostics | SCENARIO 2 |
| `count_recent_startup_failures()` | Crash-loop detection (N failures in M minutes) | SCENARIO 2 |
| `get_startup_metrics()` | Aggregate startup metrics for dashboards | SCENARIO 5 |
| `record_app_shutdown()` | Records graceful shutdown | — |
| `verify_app_startup_lifecycle()` | Gherkin scenario verification | All |

---

## Key Files

| File | Purpose |
|------|---------|
| `entity-management/pkg/app.go` | Composition root — DI wiring |
| `entity-management/cmd/server/main.go` | Main entry point with health checks, OTEL |
| `entity-management/internal/domain/types.go` | Domain events for app lifecycle |
| `entity-management/internal/ports/events.go` | CloudEvents envelope definitions |
| `entity-management/internal/ports/event_publisher.go` | Event publisher adapter |
| `entity-management/internal/adapters/eventbus/outbox_relay.go` | Outbox relay subject mapping |
| `entity-management/database/migrations/ENTITYMGMT-12_000_app_startup_lifecycle.up.sql` | Database migration |
| `entity-management/database/migrations/ENTITYMGMT-12_000_app_startup_lifecycle.down.sql` | Rollback migration |
| `entity-management/database/seeds/ENTITYMGMT-12_000_app_startup_lifecycle_seed.sql` | Seed data |

---

## Gherkin Scenario Verification

Run `SELECT * FROM verify_app_startup_lifecycle();` to verify all Gherkin scenarios.
