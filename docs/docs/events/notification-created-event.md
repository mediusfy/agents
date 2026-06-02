

# Domain Event: `notifications.NotificationCreated`

## Schema (Sketch)

```json
{
  "eventId": "uuid",
  "eventType": "notifications.NotificationCreated",
  "eventVersion": "1.0",
  "occurredAt": "2025-03-21T10:30:00Z",
  "data": {
    "notificationId": "uuid",
    "message": "string",
    "priority": "string (low|medium|high)",
    "createdAt": "ISO-8601 timestamp",
    "status": "string (created)"
  }
}
```

## Owner
**Bounded Context**: Notifications

## Consumers

| Consumer | Context | Purpose |
|---|---|---|
| Audit Service | Audit.Logging | Audit trail and compliance |
| Analytics Service | Analytics.Tracking | Dashboards and metrics |
| Dispatch Service | Delivery.Dispatch | Send notification via channels |
| User Preferences Service | UserPreferences | Check opt-in preferences before delivery |
