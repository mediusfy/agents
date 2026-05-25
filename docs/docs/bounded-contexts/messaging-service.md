

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
