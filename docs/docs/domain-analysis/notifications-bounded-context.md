

# Bounded Context: Notifications

## Context Name
**Notifications** — responsible for receiving, validating, persisting, and publishing notification events.

## Ubiquitous Language

| Term | Definition |
|---|---|
| **Notification** | A domain entity consisting of a textual message, a priority level, a timestamp, and a unique ID. |
| **Priority** | A classification level for the notification. Allowed values: `low`, `medium`, `high`. |
| **Message** | The textual content of the notification. Must be non-empty. |
| **NotificationCreated** | A domain event emitted after a notification record is successfully validated and stored in PostgreSQL. |

## Ownership
- **API Endpoint**: `POST /api/notify`
- **Database Table**: `notifications`
- **Domain Events**: `notifications.NotificationCreated`

## Integration with Other Bounded Contexts

| Downstream Consumer | Integration Pattern | Purpose |
|---|---|---|
| **Audit.Logging** | Event-driven / Pub-Sub | Consumes `NotificationCreated` for audit trail and compliance logging |
| **Analytics.Tracking** | Event-driven / Pub-Sub | Consumes `NotificationCreated` for metrics, dashboards, and usage analytics |
| **UserPreferences** | Customer-Supplier (optional) | May consume events to check user opt-in/opt-out preferences before dispatching |
| **Delivery.Dispatch** | Event-driven / Pub-Sub | Consumes `NotificationCreated` to trigger downstream delivery (email, SMS, push) |

## Multi-Cloud & Data Residency Considerations
- Data residency laws may dictate where notification records can be stored (e.g., GDPR in EU, CCPA in California).
- The `POST /api/notify` endpoint deployment must be regionalized to comply with data locality requirements.
- Downstream consumers (audit, analytics) must respect regional boundaries when subscribing to events.
