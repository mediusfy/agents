

# ADR-002: Notification Service Architecture (NOTIF-01 through NOTIF-05)

## Status
Approved

## Context
User stories NOTIF-01 through NOTIF-05 require a POST /api/notify endpoint that:
- Accepts JSON with `message` (string) and `priority` (enum: low, medium, high)
- Returns 201 on success with the created record's ID
- Returns 400 on validation errors
- Returns 500 on database failures (with correlation ID in logs)
- Publishes a `notifications.NotificationCreated` domain event

## Decision

1. **Transactional Outbox Pattern**: The notification record AND the domain event must be persisted in the same database transaction. A separate outbox relay process publishes events asynchronously. This prevents data loss if the message broker is unavailable.

2. **Priority as Value Object**: Defined as a typed Go enum in the domain layer:
   - `PriorityLow`, `PriorityMedium`, `PriorityHigh`
   - Validation logic (`FromString`, `IsValid`, `AllowedValues`) lives on the type itself.

3. **Correlation ID Middleware**: Chi middleware reads/generates `X-Request-ID` and stores it in `context.Context`. All logs and errors propagate this ID.

4. **Hexagonal Package Layout**:
   - `internal/notification/domain/` — entity, value objects, events
   - `internal/notification/application/` — service, ports (interfaces)
   - `internal/notification/infrastructure/` — HTTP handler, Postgres repo, event publisher

5. **Thin Handler Pattern**: Handlers only unmarshal/marshal. All business logic is in the service layer.

6. **Graceful Shutdown**: `errgroup` + `signal.NotifyContext` for in-flight request completion.

## Consequences
- No event loss on broker downtime (outbox)
- Consistent validation across transports (CLI, HTTP, async)
- Traceable error logs across services
- Slightly increased complexity (outbox relay process needed)

## Constraints
See `architectural_constraints` from CTO review.
