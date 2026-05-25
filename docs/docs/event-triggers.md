

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
