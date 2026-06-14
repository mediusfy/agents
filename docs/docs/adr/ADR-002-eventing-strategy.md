

# ADR-002: Eventing Strategy for FinOps Cross-Service Communication

## Status
**DRAFT** — Proposed for review

## Context
We are building FINOPS-02: Automated Cost Optimization Recommendations, an event-driven service within our FinOps suite. The service needs to communicate asynchronously with other bounded contexts (TRIAGE, GITOPS, NOTIFY) to:

1. Emit cost optimization recommendations when they are generated
2. Receive resource metadata changes from TRIAGE
3. Notify NOTIFY when recommendations require user attention
4. Trigger policy re-evaluation in GITOPS when cost data changes

All services run on **Google Cloud Run (stateless, ephemeral)**. We are in **Phase 1/2 of a 3-phase delivery**. The architecture follows Go hexagonal patterns with constructor-based DI, thin handlers, errgroup concurrency, and graceful shutdown via signal.NotifyContext.

This ADR evaluates three eventing approaches to determine which best fits our constraints.

## Decision Drivers

| Driver | Weight | Description |
|--------|--------|-------------|
| Cloud Run Stateless Model | Critical | No local disk persistence, instances scale to zero, no sticky instance affinity |
| Phase 1/2 Cost Budget | Critical | Minimal managed infrastructure spend until Phase 3 validates product-market fit |
| Developer Ergonomics | High | Go-native, testable, low cognitive overhead for the team |
| Operational Complexity | High | Must not require dedicated ops team to manage messaging infrastructure |
| Latency Requirements | Medium | Near-real-time acceptable (seconds); sub-millisecond not required for cost recommendations |
| Future Scalability | Medium | Must support Phase 3 growth without full rewrite |

## Options Considered

### Option A: Firestore Transactional Outbox (Polling)

**How it works:**
- Service writes business data + outbox events atomically via Firestore transaction
- A lightweight poller goroutine queries unprocessed outbox documents (e.g., `WHERE processed = false`)
- Events are dispatched to interested consumers via internal HTTP callbacks or Cloud Events
- After successful processing, the outbox document is marked `processed = true` or deleted (with TTL policy)

**Architecture sketch:**
```
[Service A] --(tx write)--> [Firestore: outbox_events] <--(poll)--- [Poller Goroutine]
                                                                        |
                                                          [Dispatch to Consumers]
```

**Pros:**
- ✅ **Zero additional infrastructure** — Firestore is already in GCP, no new broker to manage
- ✅ **Cloud Run native** — No persistent state required on the instance; Firestore handles durability
- ✅ **Transactional guarantees** — Business data and events written atomically
- ✅ **Cost-effective** — Pay per document read/write; estimated <$10/month at Phase 1/2 volumes
- ✅ **Simple to test** — Firestore emulator for local dev, no external broker dependency
- ✅ **TTL policies** — Firestore native TTL auto-cleans stale events
- ✅ **No network reconfiguration** — No need for VPC peering to a message broker
- ✅ **Migratable** — Can add CDC (Change Data Capture) to Pub/Sub in Phase 3 for real-time

**Cons:**
- ❌ **Polling latency** — Best effort: 1–5 second polling interval; not real-time
- ❌ **Polling overhead** — Empty polls consume read ops and CPU on idle systems
- ❌ **Manual consumer groups** — Each consumer must track its own cursor or use Firestore queries
- ❌ **Throughput ceiling** — ~1000 events/sec before Firestore write contention becomes an issue
- ❌ **No native ordering** — No ordered partition guarantees without application-level sequencing
- ❌ **No built-in retry/DLQ** — Must be implemented in application code

### Option B: Embedded NATS (nats-io/nats.go JetStream)

**How it works:**
- NATS server embedded via `nats-server` library within each Go service binary
- Services use JetStream for persistent streams with at-least-once delivery
- Event publishing and consuming within the same process or across instances via NATS cluster

**Architecture sketch:**
```
[Service A: NATS embedded] --(JetStream)--> [Service B: NATS embedded]
         |                                            |
    [ephemeral disk]                            [ephemeral disk]
```

**Pros:**
- ✅ **Low latency** — Sub-millisecond pub/sub within same process
- ✅ **Excellent Go client** — `nats.go` is idiomatic, well-maintained, and ergonomic
- ✅ **Rich features** — JetStream persistence, exactly-once semantics, key-value store, object store
- ✅ **Streaming semantics** — Consumer groups, ordered delivery, replay

**Cons:**
- ❌ **❌ CRITICAL: Cloud Run stateless violation** — JetStream stores data on disk. Cloud Run filesystems are ephemeral and disappear when the instance shuts down (~15 min idle → scale-to-zero). **All events are lost on scale-down.**
- ❌ **❌ CRITICAL: Cluster formation impossible** — NATS clustering requires stable member addresses. Cloud Run instances have dynamic IPs and no sticky routing. Instances cannot discover each other reliably.
- ❌ **Operational complexity** — Embedded NATS in Cloud Run requires workarounds (external volumes via Filestore/NFS — anti-pattern for serverless)
- ❌ **Vendor lock-in risk** — Deep NATS dependency would be costly to replace
- ❌ **Cost** — Even if embedded, would need external persistent storage (Filestore ~$200+/month) to achieve durability
- ❌ **Cold start latency** — NATS server initialization adds 1–3 seconds to cold starts

### Option C: Kafka (via Confluent Cloud)

**How it works:**
- Fully managed Kafka cluster via Confluent Cloud or Aiven
- Services produce/consume events via `confluent-kafka-go` (librdkafka) or `segmentio/kafka-go`
- Topics partitioned by event type; consumer groups for load balancing

**Architecture sketch:**
```
[Service A] --(produce)--> [Kafka Topic] <--(consume)--- [Service B]
                                   |
                        [Confluent Cloud Cluster]
```

**Pros:**
- ✅ **Industry standard** — Battle-tested event backbone at global scale
- ✅ **Durable, ordered, replayable** — Persistent logs with configurable retention
- ✅ **Consumer groups** — Automatic load balancing across Cloud Run instances
- ✅ **Scalable** — Handles millions of events/sec in Phase 3
- ✅ **Ecosystem** — Kafka Connect, Schema Registry, ksqlDB for stream processing

**Cons:**
- ❌ **❌ CRITICAL: Cost for Phase 1/2** — Confluent Cloud basic cluster starts at ~$1,000/month. A production-grade cluster with HA is $3,000–$5,000/month. **This is prohibitive for Phase 1/2.**
- ❌ **❌ SIGNIFICANT: Consumer group rebalancing on Cloud Run** — Cloud Run's scale-to-zero and dynamic scaling causes frequent consumer group rebalances (each new/departed instance triggers a rebalance). This introduces processing lag and potential duplicate processing.
- ❌ **Operational complexity** — Even managed Kafka requires VPC peering, ACLs, topic governance, schema management
- ❌ **Heavy client library** — `confluent-kafka-go` wraps C library (librdkafka), complicating builds and cross-compilation
- ❌ **Cold start impact** — librdkafka initialization and consumer group join adds 5–10s to cold starts
- ❌ **Overkill for Phase 1/2** — We don't need Kafka's throughput or features at current scale

## Evaluation Matrix

| Criterion | Firestore Outbox | Embedded NATS | Kafka (Confluent) |
|-----------|:----------------:|:--------------:|:-----------------:|
| Cloud Run Compatible | ✅ **Perfect** | ❌❌ **Fails** | ⚠️ **Problematic** |
| Phase 1/2 Cost (~$/mo) | **$5–$15** | $200+ (external storage) | **$1,000–$5,000** |
| Latency (P99) | 1–5s | <10ms | <50ms |
| Developer Ergonomics | ⭐⭐⭐ (Go SDK + emulator) | ⭐⭐⭐⭐ (best Go client) | ⭐⭐ (CGo dependency) |
| Operational Complexity | ⭐⭐⭐⭐⭐ (zero ops) | ⭐⭐ (cluster state mgmt) | ⭐⭐ (managed, but still ops) |
| Durability | ✅ Firestore native | ❌ Ephemeral in Cloud Run | ✅ Kafka native |
| Throughput Ceiling | ~1K events/sec | ~1M events/sec | ~1M+ events/sec |
| Migration to Phase 3 | ✅ CDC to Pub/Sub/Kafka | ❌ Full rewrite needed | ✅ Already in place |

## Decision

**Chosen: Option A — Firestore Transactional Outbox (Polling)**

### Rationale

1. **Cloud Run Respect**: Firestore outbox is the only option that fully respects Cloud Run's stateless, ephemeral nature. Embedded NATS fundamentally violates this constraint. Kafka can work but introduces severe cost and operational friction.

2. **Phase 1/2 Pragmatism**: We are validating product-market fit. Spending $1,000–$5,000/month on Kafka infrastructure or engineering workarounds for embedded NATS on Cloud Run is premature. Firestore outbox costs ~$10/month at Phase 1/2 volumes.

3. **Transactional Integrity**: The outbox pattern provides exactly the guarantees we need — if a recommendation is saved, its event is saved. No dual-write problem. No lost events on scale-down.

4. **Sufficient Latency**: Cost recommendations don't need millisecond delivery. Polling every 3–5 seconds is well within acceptable bounds for "a new recommendation is available."

5. **Growth Path**: This decision explicitly includes a migration path to Pub/Sub (native GCP) or Kafka in Phase 3 via Firestore CDC, avoiding vendor lock-in.

### Consequences

**Positive:**
- Zero additional infrastructure to manage
- Fast development velocity — no broker setup, no VPC peering, no ACL management
- Easy local development with Firestore Emulator
- Well-understood transactional outbox pattern

**Negative:**
- Must build polling, idempotent dispatch, and retry logic in application code
- Polling latency means eventual consistency (acceptable for this use case)
- Must implement consumer group semantics ourselves if needed (e.g., shard by recommendation_id)
- Not suitable if requirements evolve to sub-second event delivery

**Neutral:**
- Phase 3 migration to Pub/Sub or Kafka requires adding CDC infrastructure (e.g., Firestore triggers → Pub/Sub, or Debezium → Kafka)
- Code written for outbox dispatch should be abstracted behind an `EventPublisher` interface to ease this migration

## Implementation Guidance

### Poller Design (Go)

```go
// EventPublisher interface for testability and future migration
type EventPublisher interface {
    Publish(ctx context.Context, event Event) error
}

// OutboxPoller implements the polling loop
type OutboxPoller struct {
    db        *firestore.Client
    publisher EventPublisher
    interval  time.Duration
    batchSize int
}

func (p *OutboxPoller) Run(ctx context.Context) error {
    ticker := time.NewTicker(p.interval)
    defer ticker.Stop()
    for {
        select {
        case <-ctx.Done():
            return ctx.Err()
        case <-ticker.C:
            p.processBatch(ctx)
        }
    }
}
```

### Required Patterns

| Pattern | Implementation |
|---------|---------------|
| Idempotent Events | Each event carries `event_id (UUID v7)` and consumer deduplicates via event store |
| Retry with Backoff | Unprocessed events older than N seconds get retried (exponential backoff via Firestore `retry_count` field) |
| Dead Letter Queue | Events exceeding max retries moved to `failed_events` collection with TTL |
| Consumer Groups | Each consumer writes a cursor document with `last_processed_event_id` for resume |
| Graceful Shutdown | `signal.NotifyContext` + errgroup to drain current batch before shutdown |

### Migration Path to Phase 3

```
Phase 1/2: Firestore Outbox Polling
                ↓
Phase 3: Enable Firestore CDC → Pub/Sub (or Debezium → Kafka)
                ↓
Phase 3+: Replace outbox writer with direct Pub/Sub producer (via EventPublisher interface)
```

## Related Decisions

- ADR-001: Health Check Endpoint Pattern (healthz/liveness/readiness)
- This ADR supersedes any prior ad-hoc eventing choices in earlier passes

## Affected Components

| Component | Impact |
|-----------|--------|
| FINOPS-02 Recommendation Engine | MUST implement outbox table write in tx with business data |
| FINOPS-02 Poller Service | MUST implement OutboxPoller with graceful shutdown |
| TRIAGE Context | MAY adopt same pattern for resource change events |
| GITOPS Policy Engine | MUST be able to ingest events from Firestore outbox |
| NOTIFY Service | MUST consume events via poller or expose internal HTTP endpoint |

## Appendix: Firestore Outbox Document Schema

```
Collection: outbox_events
Document ID: auto-generated (Firestore)
Fields:
  - event_id: string (UUID v7)
  - event_type: string (e.g., "cost_recommendation.created")
  - source: string (e.g., "fino-02")
  - subject: string (e.g., "recommendation/abc-123")
  - data: map (event payload, CloudEvents-compliant)
  - processed: boolean (default: false)
  - created_at: timestamp
  - retry_count: number (default: 0)
  - last_error: string (nullable)

Indexes:
  - Composite: (processed, created_at) ASC
TTL Policy: Auto-delete documents older than 7 days
```

---

*Approved by: CTO Agent*
