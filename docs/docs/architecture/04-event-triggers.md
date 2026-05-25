

# Event Triggers — Message Processing Service

## Event Catalog

### 1. `messaging.MessageReceived.v1`
| Field | Description |
|---|---|
| **Owner** | Messaging Bounded Context |
| **Trigger** | A well-formed raw message passes ACL translation and is accepted into the canonical pipeline |
| **Consumers** | Messaging (internal — proceeds to enrichment/classification) |
| **Payload (sketch)** | `{ messageId: string, source: string, canonicalPayload: object, receivedAt: timestamp, correlationId: string }` |

### 2. `messaging.MessageRejected.v1`
| Field | Description |
|---|---|
| **Owner** | Messaging Bounded Context |
| **Trigger** | A raw message fails validation (missing fields, invalid format, unsupported type) |
| **Consumers** | Audit Logging (for compliance tracking), Monitoring (alerting on rejection rates) |
| **Payload (sketch)** | `{ messageId?: string, rawExcerpt: string, rejectionReason: string, validationErrors: array, correlationId: string, rejectedAt: timestamp }` |

### 3. `messaging.NotificationDetails.v1`
| Field | Description |
|---|---|
| **Owner** | Messaging Bounded Context |
| **Trigger** | A validated message is classified as 'detailed' and successfully processed |
| **Consumers** | Notification Delivery (routes to transport channels), Audit Logging (immutable record) |
| **Payload (sketch)** | `{ messageId: string, messageType: "detailed", channel: string, content: object, metadata: object, correlationId: string, timestamp: timestamp }` |
| **Routing** | No multi-cloud routing embedded — payload is topology-agnostic |

### 4. `messaging.NotificationStatus.v1`
| Field | Description |
|---|---|
| **Owner** | Messaging Bounded Context |
| **Trigger** | A validated message is classified as 'status-only' and successfully processed |
| **Consumers** | Notification Delivery (routes status to channel), Audit Logging (immutable record) |
| **Payload (sketch)** | `{ messageId: string, messageType: "status-only", statusText: string, statusCode: string, correlationId: string, timestamp: timestamp }` |
| **Routing** | No multi-cloud routing embedded — payload is topology-agnostic |

## Event Flow Diagram

```
[Raw Message] ──► [ACL] ──► validation ──► classification
                                       │
                            ┌──────────┴──────────┐
                            │                     │
                     [detailed]              [status-only]
                            │                     │
                            ▼                     ▼
              messaging.NotificationDetails  messaging.NotificationStatus
                            │                     │
                            └─────────┬───────────┘
                                      ▼
                          ┌───────────────────────┐
                          │   Message Bus         │
                          │  (Kafka / EventGrid)  │
                          └──┬──────────────┬─────┘
                             │              │
                             ▼              ▼
                   Notification        Audit
                   Delivery            Logging
```

## Schema Versioning Strategy
- Events are versioned in the event type string: `messaging.NotificationDetails.v1`
- Schema definitions are stored in a **shared schema registry** (Avro or Protobuf)
- Breaking changes increment the major version (v1 → v2)
- Backward-compatible changes (new optional fields) are additive within a major version
