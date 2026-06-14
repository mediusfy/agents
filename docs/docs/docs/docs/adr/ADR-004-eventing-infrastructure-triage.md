

# ADR-004: Eventing Infrastructure for Incident Management

**Status:** Accepted  
**Date:** 2026-06-03  
**Supersedes:** ADR-002 (refined for Cloud Run stateless model and phased rollout)  
**Phase Applicability:** Phase 1 (TRIAGE + GITOPS) with forward-looking extensions for Phase 2 (FINOPS) and Phase 3 (WORKSPACE)

---

## Context

The incident management platform requires asynchronous event-driven communication between bounded contexts (TRIAGE, GITOPS, FINOPS, WORKSPACE). This ADR selects the eventing infrastructure given:

1. **Runtime:** Cloud Run (stateless, serverless containers, scale-to-zero)
2. **Language:** Go (errgroup, graceful shutdown, hexagonal architecture)
3. **Data Residency:** EU and non-EU deployments must be supported
4. **Phased Rollout:**
   - **Phase 1:** TRIAGE + GITOPS — outbox events, no CRDT, no P2P
   - **Phase 2:** FINOPS — cost anomalies, showback, TSDB integration later
   - **Phase 3:** WORKSPACE — CRDT-based collaboration, P2P potentially needed
5. **Patterns in use:** Transactional Outbox, Disposition Error, Thin Handlers

### Options Considered

| Option | Cloud Run Fit | Data Residency | Phase 3 (CRDT/P2P) | Operational Cost |
|---|---|---|---|---|
| Firestore Outbox → Polling | ✅ Excellent | ✅ Native | ❌ Poor | Low |
| Embedded NATS | ❌ Stateful (lost on scale-down) | ❌ Complex | ✅ Excellent | Medium |
| Managed Kafka (Confluent Cloud) | ⚠️ Overhead, cold-starts | ✅ Supported | ⚠️ Possible | High |
| **Cloud Pub/Sub (chosen)** | ✅ Excellent | ✅ Native multi-region | ✅ Can bridge | Low-Medium |
| Firestore Outbox → Cloud Pub/Sub | ✅ Excellent | ✅ Native | ✅ Can bridge later | Low |

---

## Decision

**Adopt a hybrid Firestore Outbox → Cloud Pub/Sub eventing architecture.**

### How It Works

```
┌──────────────┐     ┌──────────────┐     ┌─────────────────┐
│  Go Service   │     │  Firestore   │     │  Cloud Pub/Sub  │
│  (Cloud Run)  │────▶│   Outbox     │────▶│    Topics       │────▶ Subscribers
│               │ TX  │  Collection  │     │                 │
│  - Write biz  │     │              │     │ - Incident.     │
│    data +     │     │ - scheduled_ │     │   classified    │
│    outbox     │     │   at: TTL    │     │ - RCA.suggested │
│    entry in   │     │ - region:    │     │ - cost.anomaly  │
│    same TX    │     │   eu/us      │     │ - gitops.sync   │
└──────────────┘     └──────────────┘     └─────────────────┘
                           │
                    [ Outbox Relay ]
                    (Cloud Run job or
                     Firestore Change
                     Streams → Pub/Sub)
```

### Mechanism

1. **Transactional Outbox:** Each service writes business data AND an outbox event document in the same Firestore transaction. The outbox document has `status: "pending"`, `topic`, and `payload` fields.
2. **Outbox Relay:** A dedicated Cloud Run job (or Firestore Change Streams trigger via Eventarc) polls/streams pending outbox entries, publishes them to Cloud Pub/Sub, and marks them `status: "published"`.
3. **Cloud Pub/Sub Topics (one per event type):**
   - `incident.classified`
   - `incident.rca.suggestions_generated`
   - `gitops.policy.evaluated`
   - `finops.cost.anomaly_detected`
4. **Subscribers:** Cloud Run services subscribe via Pub/Sub push or pull with exactly-once delivery semantics.
5. **Data Residency:** Separate Firestore databases + Pub/Sub topics per region (e.g., `eu-incident`, `us-incident`). Outbox Relay is region-scoped.

### Why Not Pure Firestore Polling?
- Higher latency (poll interval vs push)
- Firestore read cost scales with polling frequency
- No built-in DLQ, retry, or ordering guarantees

### Why Not NATS (now)?
- Stateful — a Cloud Run service can't own a NATS server; a managed NATS cluster adds cost and cross-region complexity
- Phase 3 CRDT/P2P requirements can be met by bridging Pub/Sub → NATS if needed, but Phase 1 doesn't need it

### Why Not Managed Kafka?
- Overkill for Phase 1 volume (incidents are intermittent, not high-throughput streaming)
- Broker cold-start latency conflicts with Cloud Run scale-to-zero
- Higher TCO for what Pub/Sub provides natively

---

## Consequences

### Positive

1. **Stateless Services:** Cloud Run services remain stateless. Event durability is handled by Firestore + Pub/Sub.
2. **Data Residency:** Trivially achieved by region-scoped Firestore databases + Pub/Sub topics. No cross-region data leakage.
3. **Go-Friendly:** The outbox write is a simple Firestore `Set` within a transaction. The relay uses the standard `cloud.google.com/go/pubsub` library.
4. **Phased Evolution:**
   - Phase 1: Outbox → Pub/Sub → subscribers (works day one)
   - Phase 2: Add `finops.*` topics, same infrastructure
   - Phase 3: If CRDT/P2P needs low-latency mesh, bridge Pub/Sub → NATS or replace — but the event schemas remain stable
5. **Cost Predictable:** Firestore writes for outbox (~1 per event), Pub/Sub publish cost (~$0.40/million). No idle infrastructure cost.
6. **Operational Overhead:** Near zero. Both Firestore and Pub/Sub are fully managed.

### Negative

1. **Two-hop latency:** Event must land in Firestore → Relay polls/pushes → Pub/Sub → subscriber. Adds ~200-500ms vs direct Pub/Sub. Acceptable for incident management (not real-time trading).
2. **Outbox Relay is a SPOF:** Mitigated by Firestore Change Streams (serverless Eventarc trigger) instead of a poller job. If using a poller, it must be idempotent and monitored.
3. **Pub/Sub ordering:** Pub/Sub offers best-effort ordering within a region. For incident management, total ordering is not required — each incident is independent.

### Constraints for Downstream Agents

- All event payloads MUST be serialized as protocol buffers (protobuf) for schema governance.
- Event schemas MUST include `event_id` (UUID v7), `source` (service name), `timestamp` (RFC 3339), and `region` (eu/us) in a common Envelope wrapper.
- Services MUST NOT read their own outbox — consume only from Pub/Sub subscriptions.
- Outbox documents MUST have a TTL of 7 days via Firestore TTL policy.

---

## Key Event Schemas

All events are wrapped in a common Envelope:

```protobuf
syntax = "proto3";
package inc.event.v1;

message EventEnvelope {
  string event_id = 1;      // UUID v7
  string source = 2;        // e.g., "triage-service"
  string event_type = 3;    // e.g., "incident.classified"
  string region = 4;        // "eu" or "us"
  google.protobuf.Timestamp timestamp = 5;
  string correlation_id = 6; // UUID v7, links related events
  bytes data = 7;           // Protobuf Any or specific payload
  map<string, string> metadata = 8; // routing hints, tenant info
}
```

### IncidentClassified

```protobuf
message IncidentClassified {
  string incident_id = 1;
  string incident_title = 2;
  enum Severity {
    SEVERITY_UNSPECIFIED = 0;
    CRITICAL = 1;
    HIGH = 2;
    MEDIUM = 3;
    LOW = 4;
  }
  Severity severity = 3;
  string category = 4;         // e.g., "availability", "latency", "security"
  string assigned_team = 5;    // team slack handle or group
  repeated string tags = 6;
  string source_service = 7;   // service that detected the incident
  string region = 8;           // "eu" or "us"
  google.protobuf.Timestamp classified_at = 9;
  string correlation_id = 10;  // links to the original alert event
}
```

**Topic:** `incident.classified`  
**Published by:** TRIAGE service  
**Consumed by:** GITOPS (policy evaluation), FINOPS (cost correlation), WORKSPACE (collaboration session init)

---

### RCASuggestionsGenerated

```protobuf
message RCASuggestionsGenerated {
  string incident_id = 1;
  string classification_id = 2; // FK to the IncidentClassified event
  repeated RCASuggestion suggestions = 3;
  string region = 4;
  google.protobuf.Timestamp generated_at = 5;

  message RCASuggestion {
    string suggestion_id = 1;
    enum Confidence {
      CONFIDENCE_UNSPECIFIED = 0;
      HIGH = 1;
      MEDIUM = 2;
      LOW = 3;
    }
    Confidence confidence = 2;
    string summary = 3;               // human-readable summary
    string root_cause_hypothesis = 4; // free-text hypothesis
    repeated string evidence_logs = 5; // log line references
    repeated string related_incidents = 6; // incident IDs with similar patterns
    string recommended_action = 7;     // e.g., "rollback deploy v1.2.3"
    map<string, string> context = 8;   // service_name -> version pairs
  }
}
```

**Topic:** `incident.rca.suggestions_generated`  
**Published by:** TRIAGE (RCA engine)  
**Consumed by:** GITOPS (auto-rollback suggestion), WORKSPACE (display to on-call), FINOPS (cost impact correlation)

---

## Migration Path from ADR-002

If ADR-002 proposed a different eventing model (e.g., pure Firestore polling or direct Pub/Sub without outbox), the migration is:

1. Add outbox collection to existing Firestore databases
2. Deploy Outbox Relay (Change Streams trigger preferred)
3. Create Pub/Sub topics and subscriptions
4. Update services to write outbox + consume from Pub/Sub (dual-run during transition)
5. Remove old polling logic after verification

---

## Future Considerations (Phase 3)

If WORKSPACE requires CRDT-based real-time collaboration with P2P mesh:
- Bridge Pub/Sub topics into a NATS cluster via a dedicated adapter service
- The adapter subscribes to Pub/Sub and publishes to NATS subjects
- Existing event schemas remain unchanged — only the transport layer changes
- This preserves the investment in protobuf schemas and the outbox pattern
