

# Message-01 Complete Specification

## Overview

This document provides the complete technical specification for MESSAGE-01 (Send Message). It covers the API contract, data model, event schema, error codes, and implementation guidelines.

## API Contract

### POST /api/v1/messages

#### Request

```
Content-Type: application/json
Authorization: Bearer <token>
```

**Body:**
```json
{
  "recipient_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
  "subject": "Meeting Tomorrow",
  "body": "Hi, can we meet tomorrow at 2pm to discuss the project?",
  "attachment_ids": [
    "7b1a8e3c-5d2f-4a9b-8c6d-1e2f3a4b5c6d"
  ]
}
```

**Validation Rules:**
| Field | Type | Required | Constraints |
|-------|------|----------|-------------|
| `recipient_id` | UUID | Yes | Must reference an existing active user; must not equal sender_id |
| `subject` | String | No | Max 200 characters |
| `body` | String | Yes | Min 1 character, Max 10,000 characters |
| `attachment_ids` | Array[UUID] | No | Max 10 attachments; each file ≤ 25MB |

#### Response (201 Created)

```json
{
  "id": "8d2a1f4e-6b3c-4a7d-9e5f-0c1d2e3f4a5b",
  "sender_id": "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d",
  "recipient_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
  "subject": "Meeting Tomorrow",
  "body": "Hi, can we meet tomorrow at 2pm to discuss the project?",
  "status": "sent",
  "created_at": "2025-03-15T10:30:00Z",
  "updated_at": "2025-03-15T10:30:00Z",
  "attachment_ids": [
    "7b1a8e3c-5d2f-4a9b-8c6d-1e2f3a4b5c6d"
  ]
}
```

#### Error Responses

| Status Code | Error Code | Description |
|-------------|------------|-------------|
| 400 | `BAD_REQUEST` | Self-messaging or malformed request |
| 401 | `UNAUTHORIZED` | Missing or invalid authentication token |
| 404 | `RECIPIENT_NOT_FOUND` | Recipient does not exist or is deactivated |
| 409 | `ATTACHMENT_NOT_FOUND` | One or more attachment IDs are invalid |
| 422 | `VALIDATION_ERROR` | Body empty, subject too long, too many attachments |
| 429 | `RATE_LIMIT_EXCEEDED` | Sender exceeded rate limit (100/hour) |

**Error Body:**
```json
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "Message body is required",
    "details": [
      {
        "field": "body",
        "issue": "must not be empty"
      }
    ]
  }
}
```

## Data Model

### messages Table

```sql
CREATE TABLE messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sender_id UUID NOT NULL REFERENCES users(id),
    recipient_id UUID NOT NULL REFERENCES users(id),
    subject VARCHAR(200),
    body TEXT NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'sent',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX idx_messages_sender ON messages(sender_id, created_at DESC);
CREATE INDEX idx_messages_recipient ON messages(recipient_id, created_at DESC);
CREATE INDEX idx_messages_status ON messages(status);
```

### message_attachments Table

```sql
CREATE TABLE message_attachments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id UUID NOT NULL REFERENCES messages(id),
    file_key VARCHAR(500) NOT NULL,
    file_name VARCHAR(255) NOT NULL,
    file_size BIGINT NOT NULL,
    mime_type VARCHAR(100) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_message_attachments_message ON message_attachments(message_id);
```

## Event Schema

### MessageSent Event

**Topic:** `messaging.message.sent`

**Schema:**
```json
{
  "event_id": "uuid",
  "event_type": "MessageSent",
  "event_version": 1,
  "producer": "messaging-service",
  "timestamp": "ISO 8601",
  "data": {
    "message_id": "uuid",
    "sender_id": "uuid",
    "recipient_id": "uuid",
    "subject": "string",
    "has_attachments": false,
    "sent_at": "ISO 8601"
  }
}
```

## Implementation Guidelines

1. **Transactional Outbox Pattern**: Use the outbox pattern to ensure reliable event publishing
2. **Idempotency**: Support idempotency key in request header (Idempotency-Key)
3. **Attachment Storage**: Store attachments in S3-compatible storage before saving message
4. **Caching**: Cache recipient lookup results for 5 minutes to reduce User Service load
5. **Audit Trail**: Log all message sends for compliance requirements
6. **Rate Limiting**: Implement sliding window counter in Redis
