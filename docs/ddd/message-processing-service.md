# Message Processing Service — DDD Analysis

## Bounded Contexts

### 1. `Messaging` (Core)
**Ubiquitous Language:**
- **Message** — an incoming payload received for processing
- **Ingestion** — the act of receiving and queueing a new message
- **Processing** — the transformation/validation/handling of a queued message
- **Notification** — the output artifact after successful processing
- **Status** — the delivery outcome (delivered, failed, pending)

**Integrations:**
- `NotificationService` — Shared Kernel (shares the notification details schema)
- `AuditLogging` — Customer-Supplier (Messaging emits events consumed by Audit)
- `Analytics` — Customer-Supplier (Messaging emits events consumed by Analytics)
- `Billing` — Customer-Supplier (consumes `NotificationStatus` for credit/refund decisions)
- `CustomerSupport` — Customer-Supplier (consumes `NotificationStatus` for case logging)

---

## Integration Patterns

| Upstream Context | Downstream Context | Pattern | Contract |
|---|---|---|---|
| Messaging | NotificationService | Shared Kernel | `NotificationDetailsEvent` payload schema |
| Messaging | AuditLogging | Customer-Supplier | `NotificationDetailsEvent` + `NotificationStatus` |
| Messaging | Analytics | Customer-Supplier | `NotificationDetailsEvent` + `NotificationStatus` |
| Messaging | Billing | Customer-Supplier | `NotificationStatus` (delivered/failed) |
| Messaging | CustomerSupport | Customer-Supplier | `NotificationStatus` (failed only) |

---

## Event Triggers

### `messaging.MessageReceived`
- **Owner:** Messaging
- **Consumers:** — (internal; signals ingestion complete, queued for processing)
- **Payload:**
  ```json
  {
    "messageId": "string",
    "receivedAt": "ISO-8601",
    "source": "string",
    "payloadSize": "number"
  }
  ```

### `messaging.NotificationProcessed`
- **Owner:** Messaging
- **Consumers:** NotificationService, AuditLogging, Analytics
- **Payload:**
  ```json
  {
    "notificationId": "string",
    "messageId": "string",
    "recipient": "string",
    "channel": "string (email|sms|push)",
    "status": "string (delivered|failed|pending)",
    "timestamp": "ISO-8601"
  }
  ```

### `messaging.NotificationStatus`
- **Owner:** Messaging
- **Consumers:** NotificationDashboard, Billing, CustomerSupport
- **Payload:**
  ```json
  {
    "messageId": "string",
    "status": "enum (delivered|failed|pending)",
    "timestamp": "ISO-8601",
    "outcomeDetails": "string? (error reason or delivery metadata)"
  }
  ```

---

## Quality Gate Flags

- **None.** All stories are clearly defined with measurable Gherkin criteria and mapped to at least one event trigger.
