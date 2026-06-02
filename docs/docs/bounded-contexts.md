# Bounded Contexts

## 1. Notifications Context

**Domain**: Notification ingestion and management  
**Ownership**: Notification Service Team  
**Database**: PostgreSQL (`notifications` schema)  
**API Surface**: `POST /api/notify`

### Ubiquitous Language

| Term | Definition |
|------|-----------|
| **Notification** | A discrete message record stored in the system with an ID, message text, priority level, and timestamp. |
| **Message** | The free-text content of the notification (1-500 characters). |
| **Priority** | The urgency level of the notification. Enum: `low`, `medium`, `high`. |
| **Created At** | Server-assigned UTC timestamp when the notification record is persisted. |

### Integration Patterns

| Pattern | Partner Context | Direction | Artifact |
|---------|----------------|-----------|----------|
| **Event Publisher** | Any downstream context (future) | Outbound | `notifications.NotificationCreated` — emitted after successful persistence to PostgreSQL. Downstream services can subscribe to trigger follow-up actions (e.g., push, email, Slack). |

### Business Rules

1. `message` is required and must be non-empty (1–500 characters).
2. `priority` is required and must be one of: `low`, `medium`, `high`.
3. JSON content type (`application/json`) is required.
4. On success, return HTTP 201 with the created record UUID.
5. On validation failure, return HTTP 422 with detailed field-level error messages.
6. On malformed JSON, return HTTP 400.
7. On wrong content type, return HTTP 415.
8. No record is persisted on any validation or parsing failure.
