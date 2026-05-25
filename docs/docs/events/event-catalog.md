

# Domain Event Catalog

## 1. `messaging.MessageRejected` ⚠️ *Flagged / Proposed*
| Property | Value |
|----------|-------|
| **Owner Bounded Context** | Messaging |
| **Description** | Emitted when an incoming message fails validation (missing required fields, wrong data types). Currently NOT implemented per MESSAGE-01 Gherkin (`And no event is emitted`). Proposed for future to support monitoring/alerting. |
| **Payload (sketch)** | `{ messageId, reason, rejectedFields[], source, timestamp, rawPayload (sanitized) }` |
| **Potential Consumers** | Monitoring, Alerting, Auditing contexts |

## 2. `messaging.NotificationDetailsExtracted`
| Property | Value |
|----------|-------|
| **Owner Bounded Context** | Messaging |
| **Description** | Emitted when a validated incoming message containing notification-relevant fields (title, body, recipient) is processed successfully. |
| **Payload (sketch)** | `{ messageId, senderId, timestamp, correlationId, title, body, recipient, locale?, priority? }` |
| **Consumers** | NotificationDispatch context, Auditing context |

## 3. `messaging.NotificationStatus`
| Property | Value |
|----------|-------|
| **Owner Bounded Context** | Messaging |
| **Description** | Emitted when a validated incoming message containing status-relevant fields (statusCode, statusMessage, source) is processed successfully. |
| **Payload (sketch)** | `{ messageId, senderId, timestamp, correlationId, statusCode, statusMessage, source, details? }` |
| **Consumers** | Status tracking/notification services, Auditing context |
