# Event Triggers — Message Processing Service

## Domain Events Summary

| Event Name | Owner | Consumers | Trigger Condition |
|---|---|---|---|
| `messaging.MessageReceived` | Messaging Context | Processing pipeline, Monitoring | Raw message accepted and queued |
| `messaging.MessageValidated` | Messaging Context | Canonicalization process, Monitoring | Message passes schema validation |
| `messaging.MessageValidationFailed` | Messaging Context | Notification context, Monitoring | Message fails schema validation |
| `messaging.MessageCanonicalized` | Messaging Context | Downstream routing, Event Store | Message transformed to canonical format |
| `messaging.MessageStatusTransitioned` | Messaging Context | Monitoring, Alerting, Workflow engine | Any status change (received→validating→processed→failed) |
| `messaging.MessageProcessingFailed` | Messaging Context | Dead-letter queue, Alerting, Monitoring | Processing (validation or transformation) fails |
| `messaging.NotificationDetailsEvent` | Messaging Context | Notification Delivery, Audit Log, Analytics | Successful processing complete |
| `messaging.NotificationStatus` | Messaging Context | Orchestration, Status dashboard, Monitoring | Every lifecycle status transition (esp. 'Processed', 'Failed', 'ValidationFailed') |

## Event Payload Schemas (sketches)

### messaging.MessageReceived
```json
{
  "eventName": "messaging.MessageReceived",
  "version": "1.0",
  "timestamp": "2025-01-01T00:00:00Z",
  "data": {
    "messageId": "uuid",
    "source": "string",
    "payload": "raw string"
  }
}
```

### messaging.MessageValidated
```json
{
  "eventName": "messaging.MessageValidated",
  "version": "1.0",
  "timestamp": "2025-01-01T00:00:00Z",
  "data": {
    "messageId": "uuid",
    "validationResult": "passed",
    "validationRulesApplied": ["schema-check", "size-limit", "format-check"]
  }
}
```

### messaging.MessageValidationFailed
```json
{
  "eventName": "messaging.MessageValidationFailed",
  "version": "1.0",
  "timestamp": "2025-01-01T00:00:00Z",
  "data": {
    "messageId": "uuid",
    "status": "ValidationFailed",
    "errors": [
      {"field": "path.to.field", "reason": "required_field_missing", "code": "VAL-001"}
    ]
  }
}
```

### messaging.MessageCanonicalized
```json
{
  "eventName": "messaging.MessageCanonicalized",
  "version": "1.0",
  "timestamp": "2025-01-01T00:00:00Z",
  "data": {
    "messageId": "uuid",
    "originalMessageId": "uuid",
    "canonicalPayload": { "...": "..." }
  }
}
```

### messaging.MessageStatusTransitioned
```json
{
  "eventName": "messaging.MessageStatusTransitioned",
  "version": "1.0",
  "timestamp": "2025-01-01T00:00:00Z",
  "data": {
    "messageId": "uuid",
    "previousStatus": "validating",
    "currentStatus": "processed",
    "transitionAt": "2025-01-01T00:00:00Z"
  }
}
```

### messaging.MessageProcessingFailed
```json
{
  "eventName": "messaging.MessageProcessingFailed",
  "version": "1.0",
  "timestamp": "2025-01-01T00:00:00Z",
  "data": {
    "messageId": "uuid",
    "status": "Failed",
    "errorCode": "PROC-ERR-001",
    "errorMessage": "Transformation failed: invalid field mapping",
    "deadLetterQueue": "dlq-messages",
    "originalPayload": "raw string (truncated if large)"
  }
}
```

### messaging.NotificationDetailsEvent
```json
{
  "eventName": "messaging.NotificationDetailsEvent",
  "version": "1.0",
  "timestamp": "2025-01-01T00:00:00Z",
  "data": {
    "messageId": "uuid",
    "notificationType": "email|sms|push",
    "recipient": "string",
    "subject": "string",
    "body": "string",
    "metadata": {
      "processingLatencyMs": 142,
      "originalReceivedAt": "2025-01-01T00:00:00Z",
      "processedAt": "2025-01-01T00:00:01Z"
    }
  }
}
```

### messaging.NotificationStatus
```json
{
  "eventName": "messaging.NotificationStatus",
  "version": "1.0",
  "timestamp": "2025-01-01T00:00:00Z",
  "data": {
    "messageId": "uuid",
    "status": "Processed|Failed|ValidationFailed",
    "previousStatus": "string",
    "statusTimestamp": "2025-01-01T00:00:00Z"
  }
}
```

## Event Flow Diagram (text)
```
[Client] --POST--> [Messaging Context]
                       |
                       |--(validates)--> messaging.MessageValidated / messaging.MessageValidationFailed
                       |
                       |--(canonicalizes)--> messaging.MessageCanonicalized
                       |
                       |--(completes)-----> messaging.NotificationDetailsEvent  (→ Notification Delivery)
                       |                    messaging.NotificationStatus         (→ Dashboards, Alerting)
                       |
                       |--(on failure)----> messaging.MessageProcessingFailed    (→ Dead-Letter Queue)
                                             messaging.NotificationStatus        (→ Monitoring)

Every transition: messaging.MessageStatusTransitioned (→ Observability)
```


# Event Triggers

## Overview

This document maps each domain event to its trigger (the action that causes the event to be published) and the consumers that react to it.

## Event Trigger Mapping

### Messaging Service

| Event | Trigger | Producer | Consumers |
|-------|---------|----------|-----------|
| `MessageCreated` | User saves a draft message | Messaging Service | Notification Service (none), Audit Service |
| `MessageSent` | User submits a message for delivery | Messaging Service | Notification Service, Audit Service |
| `MessageDelivered` | Message is placed in recipient's inbox | Messaging Service | Notification Service |
| `MessageRead` | Recipient opens the message | Messaging Service | Notification Service (read receipts), Audit Service |
| `ThreadCreated` | First message in a new thread is sent | Messaging Service | Notification Service |
| `MessageDeleted` | User or system deletes a message | Messaging Service | Storage Service (cleanup attachments), Audit Service |

### User Service

| Event | Trigger | Producer | Consumers |
|-------|---------|----------|-----------|
| `UserRegistered` | New user completes registration | User Service | Messaging Service (welcome message), Notification Service |
| `UserLoggedIn` | User authenticates | User Service | Audit Service |
| `UserProfileUpdated` | User updates their profile | User Service | Messaging Service (update cached data) |

## Trigger Details

### MessageSent Trigger

**Triggering Actions:**
1. Client sends POST `/api/v1/messages` with valid payload
2. System validates recipient exists and is active
3. System validates message content (body required, subject optional)
4. System processes attachments (if any)
5. System persists message with status `sent`
6. System publishes `MessageSent` event

**Conditions:**
- Must pass all validation rules
- Sender must not exceed rate limit
- Sender must not be sending to self

**Rollback:**
- If event publishing fails after DB insert, the outbox pattern ensures eventual publication
- If attachment storage fails, the entire operation is rolled back

### MessageRead Trigger

**Triggering Actions:**
1. Client sends POST `/api/v1/messages/{id}/read`
2. System verifies the requesting user is the recipient
3. System updates message status to `read`
4. System publishes `MessageRead` event

**Conditions:**
- Only the recipient can mark a message as read
- Sender's read receipt preference must be respected (if recipient has disabled read receipts, the event is still published but a flag indicates receipts are disabled)

## Consumer Behaviors

| Consumer | Event | Behavior |
|----------|-------|----------|
| Notification Service | `MessageSent` | Send push notification to recipient device |
| Notification Service | `MessageDelivered` | Update notification status to delivered |
| Notification Service | `MessageRead` | Update notification status to read (if applicable) |
| Audit Service | `MessageSent` | Create audit log entry for compliance |
| Audit Service | `MessageRead` | Create audit log entry for read receipt |
| Storage Service | `MessageDeleted` | Schedule attachment cleanup job |
