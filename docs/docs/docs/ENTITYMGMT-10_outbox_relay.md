

# ENTITYMGMT-10: Domain Events Reliably Published via Transactional Outbox Over NATS

## Overview

Story: Domain events are reliably published via the transactional outbox pattern over NATS.

This migration enhances the existing `outbox_events` table (created in ENTITYMGMT-01) with relay-specific columns and supporting SQL functions, enabling the outbox relay to reliably process, publish, and monitor domain events.

## Gherkin Scenario Mapping

### SCENARIO 1: Entity creation within UnitOfWork
```
Given a create entity transaction begins
When the entity is saved to the entities table
  AND the EntityCreated outbox event is saved to the outbox_messages table
Then both operations occur within the same UnitOfWork database transaction
  And the outbox event has status="pending"
```

**Implementation:**
- `UnitOfWork.Execute()` in `internal/adapters/postgres/postgres_repo.go` wraps entity save + outbox save in a single pgx transaction
- `domain.Service.CreateEntity()` in `internal/domain/service.go` calls `uow.Execute()` with both `entities.Save()` and `outbox.Save()`
- Outbox event status defaults to `'pending'` via the CHECK constraint on `outbox_events.status`

### SCENARIO 2: Outbox relay publishes pending events to NATS
```
Given an outbox event with status="pending"
When the outbox relay goroutine processes it
Then the event is published to NATS on subject "entitymanagement.entity.created"
  And the outbox event status is updated to "published"
  And the relay processes events in FIFO order
```

**Implementation:**
- `OutboxRelay` goroutine in `internal/adapters/eventbus/outbox_relay.go` polls `fetch_pending_outbox_events()` every 500ms
- `mark_outbox_published(event_id, nats_subject)` sets `status='published'`, `published_at=NOW()`, records the NATS subject
- `subjectMapping` maps domain event types to NATS subjects (e.g., `entity.created` → `entitymanagement.entity.created`)
- FIFO order enforced by `ORDER BY created_at ASC, id ASC` in `fetch_pending_outbox_events()`

### SCENARIO 3: Retry with exponential backoff on failure
```
Given an outbox event fails to publish to NATS (network error, NATS unavailable)
When the relay retries
Then it retries with exponential backoff (1s, 2s, 4s) up to max_retries (default 3)
  If max retries exhausted, event status is set to "failed"
  And a critical alert metric is incremented
```

**Implementation:**
- `computeBackoff(attempt)` in `outbox_relay.go`: 1s, 2s, 4s (formula: `1s * 2^(attempt-1)`)
- Default max retries: `DefaultMaxRetries = 3` (configurable via `WithMaxRetries(n)`)
- On max retry exhaustion: `mark_outbox_failed(event_id, error)` sets `status='failed'`, increments `retry_count`
- Critical alert: `failedCounter` OpenTelemetry metric incremented with attribute `reason="max_retries_exhausted"`
- `enqueue_outbox_event_failed()` enqueues a `entitymanagement.outbox.event_failed` lifecycle event for DLQ processing

### SCENARIO 4: NoopEventBus fallback when NATS unavailable
```
Given the NATS connection was unavailable at startup
When a noopEventBus fallback is used
Then events are logged at DEBUG level instead of published
  And the service continues to operate in degraded mode
```

**Implementation:**
- `NoopBus` in `internal/adapters/eventbus/noop.go` implements `ports.EventBus`
- All `Publish()` calls log at DEBUG level with full envelope metadata
- All `Subscribe()` calls log at DEBUG level and never invoke the handler
- The service continues operating normally; domain data is persisted correctly

## Enhanced outbox_events Columns

This migration adds the following columns to `outbox_events` (originally created in ENTITYMGMT-01):

| Column | Type | Description |
|--------|------|-------------|
| `published_at` | TIMESTAMPTZ | Timestamp when the outbox relay successfully published this event to NATS |
| `nats_subject` | TEXT | NATS subject this event was published to (e.g., `entitymanagement.entity.created`) |
| `processed_at` | TIMESTAMPTZ | Timestamp when the outbox relay picked up this event for processing |
| `max_retries` | SMALLINT | Per-event max retry override (NULL = use relay default of 3) |

## Relay SQL Functions

### Relay Processing Functions

| Function | Purpose | Gherkin |
|----------|---------|---------|
| `fetch_pending_outbox_events(batch_size)` | FIFO fetch with `FOR UPDATE SKIP LOCKED` for concurrent safety | SCENARIO 2 |
| `mark_outbox_published(event_id, nats_subject)` | Sets status='published', records timestamp and subject | SCENARIO 2 |
| `mark_outbox_failed(event_id, error)` | Sets status='failed', increments retry_count, records error | SCENARIO 3 |
| `mark_outbox_retry(event_id, error)` | Increments retry_count, keeps status='pending' for retry | SCENARIO 3 |

### Lifecycle Event Functions

| Function | Purpose | NATS Subject |
|----------|---------|-------------|
| `enqueue_outbox_event_published(outbox_event_id, aggregate_id, event_type, nats_subject, published_at, latency_ms)` | Emits event_published lifecycle event | `entitymanagement.outbox.event_published` |
| `enqueue_outbox_event_failed(outbox_event_id, aggregate_id, event_type, retry_count, last_error, failed_at)` | Emits event_failed lifecycle event | `entitymanagement.outbox.event_failed` |

### Relay Management Functions

| Function | Purpose |
|----------|---------|
| `count_pending_outbox_events()` | Total pending events (backlog depth) |
| `count_stalled_outbox_events(threshold_seconds)` | Events picked up but not published within threshold |
| `reset_stalled_outbox_events(threshold_seconds)` | Clears processed_at on stalled events for retry |
| `get_outbox_latency_ms(event_id)` | End-to-end latency from creation to publication |
| `get_outbox_event_by_id(event_id)` | Retrieves a single outbox event |
| `list_failed_outbox_events(limit, offset)` | Dead-letter queue listing |
| `replay_failed_outbox_event(event_id)` | Resets failed event to pending for manual replay |

## Lifecycle Event Payloads

### entitymanagement.outbox.event_published

```json
{
  "outbox_event_id": "uuid-of-outbox-event",
  "aggregate_id": "uuid-of-aggregate",
  "event_type": "entity.created",
  "nats_subject": "entitymanagement.entity.created",
  "published_at": "2026-01-15T10:30:00.500Z",
  "latency_ms": 500
}
```

**Consumers:** ObservabilityContext (delivery latency metrics, throughput monitoring)

### entitymanagement.outbox.event_failed

```json
{
  "outbox_event_id": "uuid-of-outbox-event",
  "aggregate_id": "uuid-of-aggregate",
  "event_type": "entity.updated",
  "retry_count": 3,
  "last_error": "NATS connection refused: dial tcp ...",
  "failed_at": "2026-01-15T10:30:07.000Z"
}
```

**Consumers:** AlertingSystem (trigger ops alert), DeadLetterQueue (store for manual replay)

## Outbox Relay Architecture

```
┌─────────────────────────────────────────────────────┐
│ Service (Go binary)                                 │
│                                                      │
│  ┌──────────────────────────────────────┐            │
│  │ UnitOfWork (pgx transaction)         │            │
│  │  ├─ Save entity to entities table    │            │
│  │  └─ Save event to outbox_events      │  ┌─────┐  │
│  │    (status='pending')               │  │NATS │  │
│  └──────────┬───────────────────────────┘  │Bus  │  │
│             │                              │     │  │
│  ┌──────────▼───────────────────────────┐  │     │  │
│  │ OutboxRelay (background goroutine)   │  │     │  │
│  │  Loop:                               │  │     │  │
│  │    1. Poll fetch_pending_outbox_events│  │     │  │
│  │    2. For each event (FIFO):         │──┼──►  │  │
│  │       a. Resolve NATS subject        │  │     │  │
│  │       b. Publish with exponential    │  │     │  │
│  │          backoff (1s, 2s, 4s)        │  │     │  │
│  │       c. On success: mark_published  │  │     │  │
│  │       d. On max retries: mark_failed │  │     │  │
│  └──────────────────────────────────────┘  └─────┘  │
│                                                      │
│  If NATS unavailable at startup:                    │
│    NoopBus logs at DEBUG level (degraded mode)       │
└─────────────────────────────────────────────────────┘
```

## Redis Cache Integration

See `config/redis/outbox_relay.conf` for the complete cache configuration.

| Key Pattern | TTL | Purpose |
|------------|-----|---------|
| `outbox:relay:last_poll` | 10s | Prevent duplicate relay cycles |
| `outbox:relay:stall_count` | 60s | Running count of stalled events |
| `outbox:relay:consecutive_failures` | 300s | Circuit breaker for relay |
| `outbox:relay:last_published:{event_type}` | 3600s | Last published timestamp per type |
| `outbox:relay:rate_limit:{event_type}` | 1s | Rate limiter for lifecycle events |
| `outbox:relay:throughput:{event_type}:{hour}` | 2h | Per-hour throughput counter |
| `outbox:relay:replay_queue` | ∞ | Failed event replay queue (list) |

## Subject Mapping

Domain event types are mapped to NATS subjects via `subjectMapping` in `outbox_relay.go`:

| Domain Event Type | NATS Subject |
|------------------|-------------|
| `entity.schema.defined` | `entitymanagement.schema.defined` |
| `entity.schema.updated` | `entitymanagement.schema.updated` |
| `entity.created` | `entitymanagement.entity.created` |
| `entity.updated` | `entitymanagement.entity.updated` |
| `entity.deleted` | `entitymanagement.entity.deleted` |
| `entity.soft_deleted` | `entitymanagement.entity.soft_deleted` |
| `entity.hard_deleted` | `entitymanagement.entity.hard_deleted` |
| `entity.restored` | `entitymanagement.entity.restored` |
| `entity.read` | `entitymanagement.entity.read` |
| *(internal)* | `entitymanagement.outbox.event_published` |
| *(internal)* | `entitymanagement.outbox.event_failed` |

## Files Changed

| File | Change |
|------|--------|
| `database/migrations/ENTITYMGMT-10_000_outbox_relay.up.sql` | NEW: Add columns, functions, indexes |
| `database/migrations/ENTITYMGMT-10_000_outbox_relay.down.sql` | NEW: Rollback migration |
| `database/seeds/ENTITYMGMT-10_outbox_relay_seed.sql` | NEW: Test data for 8 scenarios |
| `config/redis/outbox_relay.conf` | NEW: Redis cache configuration |
| `docs/docs/ENTITYMGMT-10_outbox_relay.md` | NEW: This document |
