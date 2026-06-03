# ADR-002: Eventing Strategy — NATS JetStream with Outbox Pattern

**Status:** Accepted  
**Date:** 2025-01-23  
**Context:** TRIAGE-03, GITOPS-01, FINOPS-02  
**Deciders:** CTO, Backend, SRE, Database Engineers

---

## Context

The incident management platform requires cross-context eventing between four bounded contexts:

| Context | Events | Consumers |
|---|---|---|
| **TRIAGE** | `IncidentClassified`, `RunbookTriggered`, `RemediationStarted`, `RemediationCompleted`, `Escalated` | Self-healing engine, notification service |
| **GITOPS** | `PRCreated`, `PRMerged`, `PRRejected`, `InfraDrifted` | Compliance scanner, FinOps reporter |
| **FINOPS** | `CostAnomalyDetected`, `BudgetExceeded`, `ShowbackReportGenerated` | Triage classifier, notification service |

**Key Requirements:**
- Must run on Cloud Run (serverless, no persistent VMs)
- At-least-once delivery with idempotent consumer semantics
- Event ordering per aggregate ID (e.g., all events for `incident-123` in order)
- Operational simplicity — no Kafka cluster management on Cloud Run
- Integration with OpenTelemetry for trace propagation across contexts
- CloudEvents v1.0 compliant payloads

---

## Decision: NATS JetStream with Database Outbox Pattern

We will adopt **NATS JetStream** as the primary event bus, coupled with a **Transactional Outbox** pattern for guaranteed delivery. Events are written to an `outbox` table within the same database transaction as the domain aggregate, then relayed to NATS JetStream by a sidecar publisher.

### Architecture

```
┌─────────────────────────────────────────────────────┐
│                  Cloud Run Service                    │
│  ┌────────────────────────────────────┐              │
│  │         Application Process         │              │
│  │  ┌──────────┐   ┌───────────────┐  │              │
│  │  │ Aggregate │──>│  Outbox Table  │  │              │
│  │  │  (Domain) │   │  (same DB tx) │  │              │
│  │  └──────────┘   └───────┬───────┘  │              │
│  └──────────────────────────┼──────────┘              │
│                             │                          │
│  ┌──────────────────────────┼──────────┐              │
│  │     Outbox Publisher     │ (poll)   │              │
│  │  (background goroutine   │          │              │
│  │   or sidecar container)  │          │              │
│  └──────────────────────────┼──────────┘              │
└─────────────────────────────┼────────────────────────┘
                               │
                    ┌──────────▼──────────┐
                    │   NATS JetStream     │
                    │  ┌────────────────┐  │
                    │  │  "triage"       │  │ (stream)
                    │  │  "gitops"       │  │ (stream)
                    │  │  "finops"       │  │ (stream)
                    │  └────────────────┘  │
                    └──────────┬───────────┘
                               │
          ┌────────────────────┼────────────────────┐
          │                    │                     │
 ┌────────▼────────┐ ┌────────▼────────┐ ┌─────────▼─────────┐
 │  TRIAGE Consumer │ │  GITOPS Consumer│ │  FINOPS Consumer   │
 │  (Cloud Run)     │ │  (Cloud Run)    │ │  (Cloud Run)       │
 └─────────────────┘ └─────────────────┘ └───────────────────┘
```

### Outbox Table Schema (PostgreSQL)

```sql
CREATE TABLE event_outbox (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    aggregate_id   TEXT NOT NULL,
    aggregate_type TEXT NOT NULL,
    event_type     TEXT NOT NULL,
    cloud_event    JSONB NOT NULL,        -- Full CloudEvents v1.0 payload
    trace_context  JSONB,                 -- OpenTelemetry traceparent, tracestate
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    published_at   TIMESTAMPTZ,           -- NULL until published
    publish_error  TEXT,
    retry_count    INT DEFAULT 0
);

CREATE INDEX idx_outbox_unpublished 
    ON event_outbox (created_at ASC) 
    WHERE published_at IS NULL;
```

### Outbox Publisher

- Runs as a background goroutine within each service (not a separate binary)
- Polls `event_outbox WHERE published_at IS NULL ORDER BY created_at ASC LIMIT 100` every 500ms
- Publishes to NATS JetStream using the subject pattern: `<context>.<event_type>` (e.g., `triage.IncidentClassified`)
- On successful publish, sets `published_at = NOW()`
- Dead-letter after 5 retries; logs and alerts on DLQ
- Observability: metrics on publish latency, queue depth, failure rate

### NATS JetStream Configuration

- **Cloud:** Synadia Cloud or self-hosted NATS cluster (2–3 nodes across zones)
- **Streams:** One stream per bounded context (`triage`, `gitops`, `finops`)
- **Subjects per stream:** `triage.>`, `gitops.>`, `finops.>`
- **Retention:** Interest-based (messages retained until all consumers ACK)
- **MaxAge:** 72 hours
- **Replicas:** 3 (R3) for production streams
- **Consumers:** Push-based for Cloud Run (HTTP push endpoint)
- **Deduplication:** NATS Msg-Id header set to `outbox_event_id` for idempotent republish

### Event Ordering

- Events for a given aggregate (e.g., `incident-abc-123`) will be ordered within each stream partition
- NATS JetStream supports ordered delivery per subject — we use subject naming: `<context>.<aggregate_type>.<aggregate_id>.<event_type>`
- Consumers receive events in publication order per subject

---

## Options Considered

### Option 1: Embedded NATS (no outbox)

Publish directly to NATS from within the application handler.

**Pros:** Simpler, lower latency  
**Cons:** No exactly-once or at-least-once guarantees if the process crashes after DB write but before NATS publish.  
**Verdict:** Rejected — risk of lost events is too high for incident triage.

### Option 2: Firestore Outbox Polling

Write events to a Firestore `outbox` collection, poll from Cloud Scheduler.

**Pros:** Fully managed, no NATS to operate  
**Cons:** Firestore is eventually consistent — could miss events under contention; higher latency (polling every 30s+); no streaming consumers; cost scales with read volume.  
**Verdict:** Rejected — eventual consistency is unacceptable for incident state transitions.

### Option 3: Apache Kafka (Confluent Cloud)

Use Confluent Cloud Kafka with a Kafka Connect outbox source connector.

**Pros:** Battle-tested ordering, infinite retention, Kafka Connect ecosystem  
**Cons:** ~$2k/month minimum for Confluent Cloud; overkill for our event volume (<1000/s); operational complexity; Cloud Run + Kafka requires SASL/SSL and sticky routing; higher startup latency.  
**Verdict:** Rejected — cost and complexity exceed our serverless appetite.

### Option 4: Cloud Pub/Sub

Use GCP Pub/Sub with outbox pattern.

**Pros:** Native GCP, no infra to manage, exactly-once support  
**Cons:** No ordering guarantees per aggregate (Pub/Sub ordering is best-effort and requires an ordering key which still doesn't guarantee total order); no replay from custom points; 10MB message max.  
**Verdict:** Rejected — ordering guarantees insufficient.

---

## Trade-offs & Mitigations

| Concern | Mitigation |
|---|---|
| NATS adds a stateful dependency | Use Synadia Cloud (managed) or deploy a small NATS cluster (3 x t3.medium ~$90/mo). Acceptable for production incident handling. |
| Outbox adds ~500ms latency | Events are idempotent; consumers tolerate reordering within that window. Not critical for incident response. |
| Outbox table can grow | Archive published events older than 7 days via `pg_cron` or partition on `created_at`. |
| NATS JetStream push to Cloud Run needs public endpoint | Use mutual TLS or VPC SCIEG to secure push consumers. Or use pull-based consumers in sidecars. |

---

## Consequences

1. **Positive:** Strong durability guarantee — event either persists in the outbox (and eventually publishes) or the domain transaction rolls back.
2. **Positive:** CloudEvents v1.0 compliance enables polyglot consumers and structured logging.
3. **Positive:** Each bounded context owns its stream; cross-context events are forwarded by application-level subscribers (e.g., TRIAGE subscribes to FINOPS events).
4. **Negative:** The outbox pattern adds write amplification (2x DB writes per domain event).
5. **Negative:** NATS cluster becomes a critical SPOF — must be multi-region for DR.
6. **Neutral:** All inter-context communication is now asynchronous. gRPC is reserved for synchronous queries (read models).

---

## Implementation Guidance

- Use the `github.com/nats-io/nats.go` client with JetStream context
- CloudEvents serialization: use `github.com/cloudevents/sdk-go/v2` with JSON format
- Outbox publisher must use `errgroup` with `signal.NotifyContext` for graceful shutdown
- Publish metrics: `outbox_queue_depth`, `outbox_publish_latency_ms`, `outbox_dlq_count`
- Trace propagation: inject W3C trace context into CloudEvents `traceparent` extension
- Add `retry_count` and exponential backoff for transient NATS failures
- Run outbox publisher in a separate `service` layer goroutine, not in HTTP handler context

---

## References

- [NATS JetStream Documentation](https://docs.nats.io/nats-concepts/jetstream)
- [CloudEvents v1.0](https://github.com/cloudevents/spec/blob/v1.0/spec.md)
- [Transactional Outbox Pattern](https://microservices.io/patterns/data/transactional-outbox.html)
- [OpenTelemetry Trace Context](https://www.w3.org/TR/trace-context/)
