# ADR-002: Notification Service Architecture

## Status
Approved

## Context
Building a POST /api/notify endpoint for creating notifications (NOTIF-01 through NOTIF-05).

## Decision

### Package Layout (Hexagonal)
```
internal/notification/
├── handler/       # HTTP handler (thin, decode→delegate→map error)
├── service/       # Business logic, validation orchestration
├── repository/    # PostgreSQL data access
└── model/         # Domain types: Notification, Priority, ValidationError, InfrastructureError
```

### Handler Pattern
- Max 3 lines: decode JSON → call service method → map error to HTTP status
- No DB access, no validation logic, no business rules
- NOTIF-05 (405) handled at router level via chi.MethodNotAllowedHandler, NOT in handler body

### Priority as Typed Value Object
- `model/priority.go` with `ParsePriority(string)` constructor
- Single validation entry point; DB CHECK constraint mirrors Go type (defense-in-depth)
- Valid values: low, medium, high, critical

### Error Types
- `model.ValidationError` → HTTP 400 (for NOTIF-02, NOTIF-03)
- `model.InfrastructureError` → HTTP 500 (for NOTIF-04)
- Never conflate validation errors with infrastructure errors

### Graceful Shutdown
- errgroup + signal.NotifyContext for coordinated shutdown
- HTTP server stops accepting new requests, in-flight requests drain, DB pool closes

### Transactional Outbox
- Outbox table migration required alongside notifications table
- Prevents dual-write inconsistency when notification-created events need emission

### Correlation ID Middleware
- Required for request tracing across handler → service → repository → outbox

## Architectural Constraints
1. All validation lives in the service layer, not in the handler
2. Handler does NOT import database packages
3. Router-level 405, not handler-level
4. Context propagation (ctx) flows from handler → service → repository
5. Notification creation must write to both notifications table AND outbox table in a single transaction
