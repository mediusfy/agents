

# ADR-003: Eventing Infrastructure for GITOPS-01 Incident Response

**Status:** Proposed  
**Date:** 2025-01-17  
**Decision Deadline:** Phase 1 implementation start  
**Affected Agents:** Backend Engineer, SRE/DevOps, Database Engineer  

---

## Context

GITOPS-01 (Automated Incident Response) requires an eventing infrastructure to emit and consume lifecycle events. The service will emit events such as:

- `gitops.RemediationPRCreated`
- `gitops.CICheckCompleted`
- `gitops.PullRequestStatusPublished`

Additionally, the service must **consume** domain events from the Incident lifecycle (specifically `incident.Classified` with an assigned runbook) to trigger remediation automation.

Key constraints for Phase 1:
- **Cloud Run stateless model** — no persistent local storage, containers can be recycled at any time
- **No CRDT, no P2P** — simple producer-consumer patterns only
- **Existing GCP commitment** — Cloud SQL (PostgreSQL) already established as primary database, Pub/Sub in the approved stack
- **Operational simplicity** — team is small, Phase 1 should minimize operational burden
- **Durability** — events must not be lost during container scaling or deploys

Three options were evaluated:

### Option 1: Firestore Outbox Polling (Transactional Outbox Pattern)

Using Firestore as the outbox store. Application writes events to a Firestore `outbox` collection within the same request scope. A sidecar poller (or Cloud Scheduler job) reads unprocessed events and publishes them to a broker.

- **Pros:** Fully managed, no new infra; Firestore real-time snapshots enable near-instant polling; good for Cloud Run stateless model.
- **Cons:** Adds a second database technology (Firestore) alongside existing Cloud SQL; Firestore write costs at scale; eventual consistency of polls adds latency; Firestore is not the team's primary database expertise.

### Option 2: Embedded NATS (JetStream)

Running a NATS server embedded within the Go process or as a sidecar in Cloud Run.

- **Pros:** Extremely low latency; simple Go client library; JetStream provides persistence.
- **Cons:** **FATAL FLAW:** Cloud Run containers are ephemeral and stateless. A restart, deploy, or scale-down event destroys all un-flushed JetStream data. No shared persistence across instances. NATS cluster formation is impossible in Cloud Run's per-instance networking model. Operational complexity of tuning JetStream stream replication for zero durability.

### Option 3: Kafka (Managed e.g., Confluent Cloud or MSK)

Managed Kafka cluster.

- **Pros:** Battle-tested at scale; strong durability guarantees; rich ecosystem.
- **Cons:** **Overkill for Phase 1.** Minimum monthly cost of $500–$2000+ for a small cluster. No existing Kafka expertise on the team. Partition management, consumer group rebalancing, and schema registry add significant operational surface. Phase 1 events are low-volume (incidents are rare events).

### Option 4 (Recommended): PostgreSQL Transactional Outbox + Pub/Sub Relay

Outbox table inside the existing Cloud SQL (PostgreSQL) instance. Events are written in the same database transaction as the domain aggregate. A lightweight poller (Cloud Run job or background goroutine) reads the outbox and publishes to Pub/Sub. Downstream services subscribe via Pub/Sub push or pull subscriptions.

- **Pros:** No new database technology; fully managed (Cloud SQL + Pub/Sub); Cloud SQL transactions guarantee exactly-once write semantics; Pub/Sub provides at-least-once delivery; operational cost is negligible (existing Cloud SQL, Pub/Sub $0.40/million messages); aligns with existing GCP architecture decisions; team already knows PostgreSQL and GCP.
- **Cons:** Polling adds marginal latency (configurable: 1–5 seconds); requires an outbox cleanup job to prevent table bloat; Pub/Sub ordering guarantees require ordering keys (available but add complexity).

---

## Decision

**Adopt Option 4: PostgreSQL Transactional Outbox + Pub/Sub Relay**

The architecture:

```
┌──────────────┐     ┌──────────────────┐     ┌──────────────┐
│  Go Service  │────>│  Cloud SQL (PG)  │────>│   Outbox     │
│  (Cloud Run) │     │  ┌────────────┐  │     │   Table      │
│              │     │  │ incidents  │  │     │              │
│  Handler ────│────>│  │ outbox     │  │     │   Poller ────│──> Pub/Sub Topic
│  Service ───│────>│  │ ...        │  │     │   (Cloud Run │
│  Repository │     │  └────────────┘  │     │    Job or    │
└──────────────┘     └──────────────────┘     │    goroutine)│
                                               └──────────────┘
                                                        │
                                                        ▼
                                              ┌──────────────────┐
                                              │  Pub/Sub Topic   │
                                              │  incident.events  │
                                              └──────────────────┘
                                                        │
                                      ┌─────────────────┼─────────────────┐
                                      ▼                 ▼                  ▼
                               ┌──────────┐    ┌──────────────┐   ┌──────────────┐
                               │ GITOPS-01 │    │ Notification │   │   Future     │
                               │ (Subscriber)│  │   Service    │   │  Consumers   │
                               └──────────┘    └──────────────┘   └──────────────┘
```

**Key Implementation Details:**

1. **Outbox Table Schema:**
```sql
CREATE TABLE event_outbox (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    aggregate_type TEXT NOT NULL,        -- e.g., 'incident'
    aggregate_id   UUID NOT NULL,        -- e.g., incident UUID
    event_type     TEXT NOT NULL,        -- e.g., 'incident.classified'
    payload        JSONB NOT NULL,        -- CloudEvents-compliant payload
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    published_at   TIMESTAMPTZ           -- NULL until published
);

CREATE INDEX idx_outbox_unpublished ON event_outbox (created_at ASC)
    WHERE published_at IS NULL;
```

2. **Publishing Flow:**
   - Handler writes to domain table + outbox table in same PG transaction
   - Poller queries `WHERE published_at IS NULL ORDER BY created_at ASC LIMIT 100`
   - Publishes each row as a CloudEvent to Pub/Sub topic
   - On successful ack, sets `published_at = NOW()`
   - Cleanup job deletes rows where `published_at < NOW() - 7 days`

3. **Idempotency:**
   - Pub/Sub subscriptions use `event_id` (CloudEvents `Id`) for deduplication
   - Consumers implement idempotent handlers

4. **Polling Config:**
   - Initial poll interval: 2 seconds (adjustable)
   - Use Cloud Run Job (scheduled via Cloud Scheduler) for dedicated poller, OR
   - Embed lightweight poller goroutine in the main service (simpler for Phase 1)

---

## Consequences

**Positive:**
- ✅ Zero additional infrastructure cost (uses existing Cloud SQL and Pub/Sub)
- ✅ Strong transactional guarantees (events written atomically with domain data)
- ✅ Team works with familiar PostgreSQL and GCP services
- ✅ Pub/Sub provides buffered, durable delivery to downstream consumers
- ✅ Easy path to add consumers in future phases
- ✅ Cloud Run friendly — no state kept in containers

**Negative:**
- ❌ Marginal latency (1–5s) from polling cadence (acceptable for incident response — minutes, not milliseconds)
- ❌ Outbox table requires periodic maintenance (cleanup job)
- ❌ Poller adds one small moving part (mitigated by Cloud Run Job managed service)
- ❌ Event ordering across aggregates requires additional design if needed later

**Risks & Mitigations:**
- **Risk:** Poller falls behind under load → **Mitigation:** Use Cloud SQL read replicas for polling, or increase poll frequency
- **Risk:** Duplicate event publication → **Mitigation:** Pub/Sub + consumer idempotency keys; `published_at` check prevents double-publish from poller
- **Risk:** Outbox table grows unbounded → **Mitigation:** TTL-based cleanup (delete after 7 days or archive to BigQuery)

---

## Architectural Constraints

The following constraints are imposed on downstream agents:

1. **Affected: Backend Engineer** — All domain writes MUST go through a single database transaction that also writes to `event_outbox`. The Repository pattern MUST expose a `PublishEvent(ctx, aggregateType, aggregateID, eventType, payload)` method.
2. **Affected: Database Engineer** — Must create the `event_outbox` table in existing Cloud SQL instance with proper indexing. Must implement weekly cleanup job (can be `pg_cron` or scheduled migration).
3. **Affected: SRE/DevOps** — Must provision a Pub/Sub topic `incident.events` and a dedicated Cloud Run Job (or Scheduler + HTTP endpoint) for the outbox poller. Must set up IAM permissions for Pub/Sub publish.
4. **Affected: All consumers** — All events MUST conform to CloudEvents 1.0 specification with `type`, `source`, `id`, `specversion`, `datacontenttype`, and `data` fields.

---

## Alternatives Considered

| Criteria | Firestore Outbox | Embedded NATS | Kafka | **PostgreSQL Outbox + Pub/Sub** |
|---|---|---|---|---|
| Operational Cost | $$ (new DB) | $ (but fragile) | $$$ | **$ (existing infra)** |
| Durability | High | Low (ephemeral) | Very High | **High** |
| Latency | 1-5s | <10ms | <100ms | **1-5s** |
| Team Familiarity | Low | None | None | **High** |
| Cloud Run Fit | Good | Poor | Good | **Excellent** |
| Phase 1 Simplicity | Medium | Low | Low | **High** |

---

## References

- ADR-001: Health Check Endpoints
- ADR-002: Notification Service Architecture (event-driven + CloudEvents + hexagonal)
- [Transactional Outbox Pattern](https://microservices.io/patterns/data/transactional-outbox.html) — Chris Richardson
- [CloudEvents 1.0 Specification](https://github.com/cloudevents/spec)
