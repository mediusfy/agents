# Event Triggers

## notifications.NotificationCreated

| Property | Value |
|----------|-------|
| **Owner** | `Notifications` Bounded Context |
| **Domain Event Name** | `notifications.NotificationCreated` |
| **Version** | 1.0.0 |
| **Description** | Emitted synchronously (or via outbox pattern) after a new notification is successfully persisted to PostgreSQL via `POST /api/notify`. |
| **Triggered By** | Successful 201 response from `POST /api/notify` |
| **Routing Key** | `notification.created` |

### Payload Schema (sketch)

```json
{
  "event_id": "uuid",
  "event_name": "notifications.NotificationCreated",
  "event_version": "1.0.0",
  "occurred_at": "2025-01-01T00:00:00Z",
  "data": {
    "id": "uuid",
    "message": "string",
    "priority": "enum(low|medium|high)",
    "created_at": "2025-01-01T00:00:00Z"
  }
}
```

### Consumers

| Consumer Context | Consumption Pattern | Action |
|-----------------|-------------------|--------|
| *(future)* Downstream notification dispatch services | Event-driven (pub/sub) | Send push/email/Slack alert based on priority |

---

## Error / No-Event Scenarios

The following conditions **must not** emit any event:

| Condition | HTTP Status | Rationale |
|-----------|-------------|-----------|
| Missing `message` or `priority` | 422 | Validation failure — no record persisted |
| Empty `message` | 422 | Validation failure — no record persisted |
| `message` > 500 chars | 422 | Validation failure — no record persisted |
| Invalid `priority` (not low/medium/high) | 422 | Validation failure — no record persisted |
| Non-JSON Content-Type | 415 | Unsupported media type — request not parsed |
| Malformed JSON body | 400 | Bad request — request could not be parsed |
