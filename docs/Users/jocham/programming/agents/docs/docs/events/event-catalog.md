

# Event Catalog

## Overview

This document catalogs all domain events produced and consumed by bounded contexts within the platform.

## Convention

Events follow a naming convention of `{Entity}{Action}` in PascalCase (e.g., `MessageCreated`, `UserRegistered`).

## Messaging Service Events

| Event | Description | Payload (key fields) |
|-------|-------------|----------------------|
| `MessageCreated` | A new message has been created (but may not yet be sent) | `messageId`, `senderId`, `recipientIds`, `subject`, `timestamp` |
| `MessageSent` | A message has been dispatched for delivery | `messageId`, `senderId`, `recipientIds`, `timestamp` |
| `MessageDelivered` | A message has been successfully delivered to a recipient's inbox | `messageId`, `recipientId`, `timestamp` |
| `MessageRead` | A recipient has opened/read a message | `messageId`, `recipientId`, `timestamp` |
| `ThreadCreated` | A new message thread has been initiated | `threadId`, `participantIds`, `subject`, `timestamp` |
| `MessageDeleted` | A message has been soft-deleted | `messageId`, `deletedBy`, `timestamp` |

## User Service Events

| Event | Description | Payload (key fields) |
|-------|-------------|----------------------|
| `UserRegistered` | A new user has registered | `userId`, `email`, `timestamp` |
| `UserLoggedIn` | A user has logged in | `userId`, `timestamp` |
| `UserProfileUpdated` | User profile has been updated | `userId`, `changedFields`, `timestamp` |

## Notification Service Events

| Event | Description | Payload (key fields) |
|-------|-------------|----------------------|
| `NotificationSent` | A notification has been sent to a user | `notificationId`, `userId`, `type`, `channel`, `timestamp` |
| `NotificationFailed` | A notification delivery failed | `notificationId`, `userId`, `type`, `channel`, `error`, `timestamp` |

## Audit Service Events

| Event | Description | Payload (key fields) |
|-------|-------------|----------------------|
| `AuditLogCreated` | An audit log entry has been created | `auditId`, `action`, `actorId`, `resourceType`, `resourceId`, `timestamp` |
