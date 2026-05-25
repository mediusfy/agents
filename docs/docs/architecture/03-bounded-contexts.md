

# Bounded Contexts — Message Processing Service

## 1. Context Map Overview

```
                            ┌─────────────────┐
                            │  External Source │
                            │ (Upstream APIs)  │
                            └────────┬────────┘
                                     │ Raw Message
                                     ▼
                         ┌───────────────────────┐
                         │    Anti-Corruption    │
                         │    Layer (ACL)         │
                         │  (Translates schemas) │
                         └──────────┬────────────┘
                                    │ Canonical Message
                                    ▼
                         ┌──────────────────────┐
                         │      Messaging       │ ◄── Bounded Context #1
                         │ (Validation, Enrich- │
                         │  ment, Event Emission)│
                         └──┬─────────────┬─────┘
                            │             │
               ┌────────────┘             └────────────┐
               ▼                                        ▼
   ┌──────────────────────┐              ┌──────────────────────┐
   │  NotificationDetails │              │  NotificationStatus  │
   │  Event               │              │  Event               │
   │  (messaging.         │              │  (messaging.         │
   │   NotificationDetails│              │   NotificationStatus │
   │   .v1)               │              │   .v1)               │
   └──────────┬───────────┘              └──────────┬───────────┘
              │                                     │
              ▼                                     ▼
   ┌──────────────────────┐              ┌──────────────────────┐
   │  Notification        │              │  Audit Logging       │
   │  Delivery            │              │  (Eventual           │
   │  (Channel routing,   │              │   Consistency)       │
   │   Retry, Transport)  │              │                      │
   └──────────────────────┘              └──────────────────────┘
   Bounded Context #2                     Bounded Context #3
```

## 2. Bounded Contexts

### Context #1: Messaging (Core Domain)
- **Ubiquitous Language**: raw message, canonical message, validation, enrichment, event emission, message type classification (detailed | status-only)
- **Responsibilities**:
  - Receive raw messages via ACL
  - Validate (schema, required fields, format)
  - Enrich (add metadata, correlation ID, timestamps)
  - Classify message type (detailed vs. status-only)
  - Emit `messaging.NotificationDetails.v1` or `messaging.NotificationStatus.v1`
- **Owns Events**: `messaging.MessageReceived`, `messaging.MessageRejected`, `messaging.NotificationDetails.v1`, `messaging.NotificationStatus.v1`
- **Integration**: Strictly event-driven (emit to message bus). No direct RPC to downstream contexts.
- **Anti-Corruption Layer**: Converts external upstream schemas into internal canonical message model.

### Context #2: Notification Delivery (Supporting Subdomain)
- **Ubiquitous Language**: channel, transport, delivery attempt, retry policy, delivery status, routing slip
- **Responsibilities**:
  - Subscribe to `messaging.NotificationDetails.v1` and `messaging.NotificationStatus.v1`
  - Route notifications to appropriate channels (email, SMS, push, etc.)
  - Manage retry logic and backoff policies
  - Handle multi-cloud routing decisions and data residency constraints
  - Emit delivery status events
- **Integration**: Consumes from message bus, pushes to external transport channels.

### Context #3: Audit Logging (Generic Subdomain)
- **Ubiquitous Language**: audit trail, event log, immutable record, compliance, retention policy
- **Responsibilities**:
  - Subscribe to all events for immutable audit trail
  - Store events with timestamp, source context, correlation ID
  - Enforce data retention and compliance policies
  - Support query for compliance/forensics
- **Integration**: Eventual-consistency consumer. No synchronous calls.

## 3. Integration Patterns

| Between Contexts | Pattern | Rationale |
|---|---|---|
| External Upstream → Messaging (via ACL) | **Anti-Corruption Layer** | Protects core domain from upstream schema changes |
| Messaging → Notification Delivery | **Event-Driven / Publisher-Subscriber** | Decouples processing from delivery; independent scaling |
| Messaging → Audit Logging | **Event-Driven / Publisher-Subscriber** | Eventual consistency; no backpressure on core domain |
| Messaging → (any downstream) | **No Shared Kernel, No RPC** | Strict event bus boundary; fault isolation |

## 4. Multi-Cloud Constraints
- Multi-cloud routing decisions are owned by **Notification Delivery** context, NOT Messaging
- Messaging emits events payload-agnostic of deployment topology
- Data residency laws are enforced at the Notification Delivery layer (not at event emission)
- Use **header-based routing** or **routing slip pattern** in Notification Delivery for regional targeting
