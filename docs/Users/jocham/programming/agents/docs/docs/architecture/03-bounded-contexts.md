

# 03 - Bounded Contexts

## Overview

This document defines the bounded contexts within the platform. Each bounded context represents a distinct domain area with its own ubiquitous language, data model, and service boundaries.

## Context Map

```
┌─────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│                 │     │                  │     │                  │
│   User Service  │◄────│ Messaging Service│────►│ Notification     │
│                 │     │                  │     │ Service          │
└─────────────────┘     └──────────────────┘     └──────────────────┘
         │                       │                        │
         │                       │                        │
         ▼                       ▼                        ▼
┌─────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│                 │     │                  │     │                  │
│   Audit Service │     │  Storage Service │     │ Moderation       │
│                 │     │                  │     │ Service (future) │
└─────────────────┘     └──────────────────┘     └──────────────────┘
```

## Bounded Contexts

### 1. User Service
- **Domain**: User identity, authentication, profile management
- **Responsibilities**: Registration, login, profile CRUD, permissions
- **Data**: Users, roles, permissions, sessions
- **Events**: `UserRegistered`, `UserLoggedIn`, `UserProfileUpdated`

### 2. Messaging Service
- **Domain**: Communication between users
- **Responsibilities**: Send/receive messages, thread management, drafts, read receipts
- **Data**: Messages, threads, attachments, delivery status
- **Events**: `MessageCreated`, `MessageSent`, `MessageDelivered`, `MessageRead`, `ThreadCreated`, `MessageDeleted`
- **Dependencies**: User Service (recipient validation), Storage Service (attachments)

### 3. Notification Service
- **Domain**: User notifications and alerts
- **Responsibilities**: Push notifications, email notifications, in-app notifications
- **Data**: Notification preferences, notification history, delivery logs
- **Events**: `NotificationSent`, `NotificationFailed`
- **Dependencies**: Messaging Service (subscribes to message events)

### 4. Storage Service
- **Domain**: File storage and management
- **Responsibilities**: File upload, download, metadata management, retention policies
- **Data**: File metadata, storage references
- **Partnership with**: Messaging Service (attachments)

### 5. Audit Service
- **Domain**: Compliance and auditing
- **Responsibilities**: Logging all significant actions, retention, querying audit trails
- **Data**: Audit log entries
- **Events**: `AuditLogCreated`

### 6. Moderation Service (Future)
- **Domain**: Content moderation and policy enforcement
- **Responsibilities**: Flag and review inappropriate content, automated moderation
- **Dependencies**: Messaging Service (consumes report events)

## Communication Patterns

| Pattern | Description | Example |
|---------|-------------|---------|
| **Event-Driven** | Asynchronous event publishing via message broker | Messaging → Notification via `MessageSent` |
| **Synchronous API** | REST API calls for immediate responses | Messaging → User Service for recipient validation |
| **CQRS** | Separate read/write models | Inbox queries use optimized read models |
| **Saga** | Distributed transaction coordination | Message send + attachment linking + event publishing |
