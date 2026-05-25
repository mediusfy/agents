

# Requirement MESSAGE-01: Send Message

## Metadata

- **ID**: MESSAGE-01
- **Title**: Send Message
- **Priority**: High
- **Status**: Approved
- **Domain**: Messaging Service

## User Story

> As a registered user, I want to send a direct message to another registered user so that I can communicate privately with them.

## Acceptance Criteria

### AC1: Successful message send
- **Given** a registered sender and a registered recipient
- **When** the sender submits a message with valid content (subject, body)
- **Then** the system creates the message
- **And** the system assigns a unique message ID
- **And** the message status is set to `sent`
- **And** the recipient can view the message in their inbox
- **And** a `MessageSent` event is published

### AC2: Invalid recipient
- **Given** a registered sender
- **When** the sender submits a message to a non-existent or deactivated recipient
- **Then** the system returns a `404 Not Found` error
- **And** the message is not created

### AC3: Empty message body
- **Given** a registered sender and a registered recipient
- **When** the sender submits a message with an empty body
- **Then** the system returns a `422 Unprocessable Entity` error
- **And** the message is not created

### AC4: Message with attachment
- **Given** a registered sender and a registered recipient
- **When** the sender submits a message with a valid attachment (≤ 25MB)
- **Then** the system stores the attachment
- **And** the message includes the attachment metadata

### AC5: Rate limiting
- **Given** a registered sender
- **When** the sender exceeds 100 messages within a 1-hour window
- **Then** the system returns a `429 Too Many Requests` error

### AC6: Self-messaging
- **Given** a registered user
- **When** the user attempts to send a message to themselves
- **Then** the system returns a `400 Bad Request` error
- **And** the message is not created

## API Specification

### POST /api/v1/messages

**Request:**
```json
{
  "recipient_id": "uuid",
  "subject": "string (max 200 chars)",
  "body": "string (required, max 10000 chars)",
  "attachment_ids": ["uuid (optional)"]
}
```

**Response (201 Created):**
```json
{
  "id": "uuid",
  "sender_id": "uuid",
  "recipient_id": "uuid",
  "subject": "string",
  "body": "string",
  "status": "sent",
  "created_at": "ISO 8601 timestamp",
  "attachment_ids": ["uuid"]
}
```

## Domain Events

- `MessageSent` (see Event Catalog)

## Non-Functional Requirements

- NFR1: Message delivery latency ≤ 500ms (p95)
- NFR2: Support 1000 messages/second throughput
- NFR3: 99.9% availability for the messaging API
