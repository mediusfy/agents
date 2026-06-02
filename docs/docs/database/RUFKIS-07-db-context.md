

## RUFKIS-07: Notification System with Priority-Coded Alerts — Database Schema Design Context

### Core Entities & Tables Required

1. **notifications** — `id`, `type` (NotificationType enum), `priority` (PriorityLevel: LOW/MEDIUM/HIGH/CRITICAL), `recipient_id`, `channel` (ChannelType: IN_APP/EMAIL/PUSH), `template_id` (FK), `variables` (JSONB), `status` (DeliveryStatus: PENDING/SENT/FAILED/READ), `created_at`, `read_at`, `delivered_at`

2. **alerts** — `id`, `notification_id` (FK), `priority` (HIGH/CRITICAL only), `acknowledged_at`, `acknowledged_by`, `escalated_at`, `escalated_to`, `resolved_at`, `timeout_seconds`

3. **notification_templates** — `id`, `name`, `channel` (ChannelType), `content` (text with {{placeholders}}), `locale`, `version` (int), `created_at`, `updated_at`

4. **notification_preferences** — `user_id`, `channel` (ChannelType), `opt_in` (bool), `quiet_hours_start` (time), `quiet_hours_end` (time), `digest_frequency` (DigestFrequency: immediate/hourly/daily/weekly), `updated_at`

5. **escalation_rules** — `id`, `priority` (PriorityLevel), `timeout_seconds`, `escalate_to_role`, `escalate_to_user_id`, `max_escalation_levels`, `is_active`

6. **template_audit_log** — for tracking template changes (who, what, when)
7. **preference_audit_log** — for tracking preference changes
8. **notification_history** — searchable/filterable history with configurable retention policies (consider partitioning by date)

### Indexing Considerations
- `notifications(recipient_id, created_at DESC)` — history queries
- `notifications(status)` — delivery/failure monitoring
- `notifications(priority, status)` — alert escalation queries
- `alerts(acknowledged_at NULLS FIRST)` — unacknowledged alert queries for escalation scheduler
- `notification_templates(channel, locale, version)` — template lookups

### Retention / Partitioning
- Notification history should support configurable retention policies (consider time-based partitioning by `created_at`)
- Purged records should be logged before deletion

### Event-Driven Considerations
- Each lifecycle state change emits an event — consider an `outbox` pattern table or CDC for reliable event publishing
- The Notifications context consumes events from other bounded contexts to trigger notifications

### Priority Handling Logic
- **LOW, MEDIUM** → batch delivery, respect quiet hours
- **HIGH** → immediate delivery, bypass quiet hours
- **CRITICAL** → immediate delivery, bypass quiet hours, require acknowledgment, escalate on timeout
