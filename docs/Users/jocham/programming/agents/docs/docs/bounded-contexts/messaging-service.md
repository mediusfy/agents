# Bounded Context: Messaging Service

## Context Name
**Messaging** (also referred to as `messaging` context)

## Ubiquitous Language
| Term | Definition |
|------|------------|
| **Incoming Message** | A raw payload received by the service from an external source (API, queue, webhook). |
| **Validated Message** | An incoming message that has passed structural and semantic validation checks. |
| **Notification-Relevant Fields** | Fields within a message payload that indicate notification intent: `title`, `body`, `recipient`. |
| **Status-Relevant Fields** | Fields within a message payload that indicate status updates: `statusCode`, `statusMessage`, `source`. |
| **Malformed Message** | An incoming message that fails validation (missing required fields, wrong data types). |
| **NotificationDetailsEvent** | A domain event emitted when notification-relevant content is extracted from a validated message. |
| **NotificationStatus** | A domain event emitted when status-relevant content is extracted from a validated message. |
| **MessageRejected** | A domain event (optional/flagged) that could be emitted when a malformed message is rejected. |

## Bounded Context Boundaries
- **Owns**: Message validation logic, message routing/classification, event emission for notification and status content.
- **Consumes from**: External message producers (upstream).
- **Publishes to**: `NotificationDispatch` context, `Auditing` context, and any other subscribers needing notification or status data.

## Integration Patterns
| Partner Context | Pattern | Details |
|----------------|---------|---------|
| External Producers | **Conformist** | The Messaging context validates and conforms incoming data rather than dictating schema to upstream senders. |
| NotificationDispatch | **Publisher-Subscriber** | Messaging context publishes `messaging.NotificationDetailsExtracted`; NotificationDispatch subscribes. |
| Auditing | **Publisher-Subscriber** | Both `messaging.NotificationDetailsExtracted` and `messaging.NotificationStatus` are consumed by Auditing for traceability. |

## Multi-Cloud & Data Residency Constraints
- Incoming messages may originate from multiple geographic regions; message payloads containing PII (e.g., `recipient` in notification details) must be processed and stored in-region only.
- Events emitted (NotificationDetailsExtracted, NotificationStatus) must respect data residency: if the recipient is in EU, the event payload must not be routed through non-EU broker nodes.
- Network latency between cloud regions must be accounted for in SLA definitions (target < 500ms P99 for message validation + event emission).

## Ambiguities & Flags
- **Flag (MESSAGE-01)**: The story explicitly states "no event is emitted" when a message is rejected. However, downstream systems (alerting, monitoring, dashboards) may need to track rejection rates. Consider introducing a `messaging.MessageRejected` event as a future requirement.



## Bounded Context: Messaging Service

### Context Name
**Messaging** (also referred to as `messaging` context)

### Ubiquitous Language
| Term | Definition |
|------|------------|
| **Incoming Message** | A raw payload received by the service from an external source (API, queue, webhook). |
| **Validated Message** | An incoming message that has passed structural and semantic validation checks. |
| **Notification-Relevant Fields** | Fields within a message payload that indicate notification intent: `title`, `body`, `recipient`. |
| **Status-Relevant Fields** | Fields within a message payload that indicate status updates: `statusCode`, `statusMessage`, `source`. |
| **Malformed Message** | An incoming message that fails validation (missing required fields, wrong data types). |
| **NotificationDetailsEvent** | A domain event emitted when notification-relevant content is extracted from a validated message. |
| **NotificationStatus** | A domain event emitted when status-relevant content is extracted from a validated message. |
| **MessageRejected** | A domain event (optional/flagged) that could be emitted when a malformed message is rejected. |

### Bounded Context Boundaries
- **Owns**: Message validation logic, message routing/classification, event emission for notification and status content.
- **Consumes from**: External message producers (upstream).
- **Publishes to**: `NotificationDispatch` context, `Auditing` context, and any other subscribers needing notification or status data.

### Integration Patterns
| Partner Context | Pattern | Details |
|----------------|---------|---------|
| External Producers | **Conformist** | The Messaging context validates and conforms incoming data rather than dictating schema to upstream senders. |
| NotificationDispatch | **Publisher-Subscriber** | Messaging context publishes `messaging.NotificationDetailsExtracted`; NotificationDispatch subscribes. |
| Auditing | **Publisher-Subscriber** | Both `messaging.NotificationDetailsExtracted` and `messaging.NotificationStatus` are consumed by Auditing for traceability. |

### Multi-Cloud & Data Residency Constraints
- Incoming messages may originate from multiple geographic regions; message payloads containing PII (e.g., `recipient` in notification details) must be processed and stored in-region only.
- Events emitted (NotificationDetailsExtracted, NotificationStatus) must respect data residency: if the recipient is in EU, the event payload must not be routed through non-EU broker nodes.
- Network latency between cloud regions must be accounted for in SLA definitions (target < 500ms P99 for message validation + event emission).

### Ambiguities & Flags
- **Flag (MESSAGE-01)**: The story explicitly states "no event is emitted" when a message is rejected. However, downstream systems (alerting, monitoring, dashboards) may need to track rejection rates. Consider introducing a `messaging.MessageRejected` event as a future requirement.


# Messaging Service - Bounded Context

## Overview

The Messaging Service bounded context is responsible for managing all communication flows between the platform's users. It handles the creation, delivery, and management of messages within the system.

## Domain

The core domain of the Messaging Service is **communication** – enabling users to exchange information reliably and securely.

## Key Concepts

- **Message**: The fundamental unit of communication. Contains a sender, recipient(s), subject, body, and metadata.
- **Thread**: A grouped collection of messages sharing a common topic or origin.
- **Conversation**: A sequence of messages between two or more participants.
- **Delivery Status**: Tracks whether a message has been sent, delivered, read, or failed.
- **Notification**: An alert sent to a user when a new message arrives.

## Context Map

- **User Service** (Upstream): Provides user identity, authentication, and profile information.
- **Notification Service** (Downstream): Consumes message events to send push/email/SMS notifications.
- **Audit Service** (Downstream): Consumes message events for compliance and auditing.
- **Storage Service** (Partnership): Handles attachment storage and retrieval.

## Ubiquitous Language

| Term | Definition |
|------|------------|
| Message | A discrete unit of communication sent from one user to another |
| Thread | A collection of related messages |
| Draft | An unsent message saved by a user |
| Inbox | A user's collection of received messages |
| Outbox | A user's collection of sent messages |
| Read Receipt | An acknowledgment that a recipient has read a message |

## Events

See the [Event Catalog](../events/event-catalog.md) for details on all events emitted by this bounded context.

Key events:
- `MessageCreated`
- `MessageSent`
- `MessageDelivered`
- `MessageRead`
- `ThreadCreated`
- `MessageDeleted`

## Commands

Commands accepted by the Messaging Service:
- `SendMessage`: Create and send a new message
- `MarkAsRead`: Mark a message as read by the recipient
- `DeleteMessage`: Soft-delete a message
- `CreateDraft`: Save a message as a draft
- `ArchiveThread`: Archive an entire thread
- `ReportMessage`: Report a message for policy violation

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/messages` | POST | Send a new message |
| `/api/v1/messages/{id}` | GET | Retrieve a specific message |
| `/api/v1/messages/{id}` | DELETE | Delete a specific message |
| `/api/v1/messages/{id}/read` | POST | Mark message as read |
| `/api/v1/threads` | GET | List user's threads |
| `/api/v1/threads/{id}` | GET | Get thread with messages |

## Dependencies

- PostgreSQL (primary data store)
- Redis (caching, real-time features)
- RabbitMQ / Kafka (event publishing)
- S3-compatible storage (attachments)
