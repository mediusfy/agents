

# Bounded Contexts — Message Processing Service

## 1. Messaging Context
**Ubiquitous Language:**
- **Message:** The raw inbound payload submitted by an external sender
- **Canonical Message:** The validated and transformed internal representation
- **NotificationDetailsEvent:** A domain event emitted when processing completes successfully, containing full notification details + metadata (timestamp, messageId, processingLatencyMs)
- **NotificationStatus:** A lifecycle event emitted on every state transition (received, validating, processed, failed) including previousStatus, currentStatus, timestamp, and optionally errorCode/errorMessage
- **Dead-Letter Queue:** A holding area for messages that failed permanently after all retries

**Owns:**
- Raw message ingestion endpoint
- Message validation (schema rules)
- Message canonicalization/transformation
- `messaging.MessageReceived` event
- `messaging.MessageValidationFailed` event
- `messaging.MessageValidated` event
- `messaging.MessageCanonicalized` event
- `messaging.MessageStatusTransitioned` event
- `messaging.MessageProcessingFailed` event (with dead-letter routing)
- `messaging.NotificationDetailsEvent` event
- `messaging.NotificationStatus` event

**Integration Pattern with Downstream Consumers:** *Publisher-Subscriber* via event bus. Downstream services subscribe to `messaging.NotificationDetailsEvent` and `messaging.NotificationStatus` event streams.

## 2. Notification Delivery Context (downstream consumer)
**Ubiquitous Language:**
- **Notification:** A processed message ready for outbound delivery
- **Delivery Receipt:** Acknowledgement that a notification was sent

**Consumes:**
- `messaging.NotificationDetailsEvent` — to retrieve full payload and dispatch to notification channels (email, SMS, push, etc.)

**Integration Pattern with Messaging Context:** *Event-driven subscription* — consumes events published by the Messaging Context. Uses an Anti-Corruption Layer if the delivery channels have differing schemas.

## 3. Monitoring & Observability Context (cross-cutting)
**Consumes:**
- `messaging.NotificationStatus` — for lifecycle dashboards and alerting
- `messaging.MessageProcessingFailed` — for error rate alerting

**Integration Pattern with Messaging Context:** *Event-driven subscription* — subscribes to status and failure events for real-time dashboards and alerting rules.
