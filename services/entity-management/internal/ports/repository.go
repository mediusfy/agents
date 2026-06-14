package ports

// This file is intentionally minimal. The canonical repository interfaces
// (SchemaRepository, EntityRepository, OutboxRepository, IdempotencyStore,
// SchemaValidator, RequestIdempotencyStore, UnitOfWork) are defined within
// the domain package where they are consumed, in accordance with the
// "interfaces defined at the consumer site" principle of Hexagonal Architecture.
//
// See: internal/domain/types.go (SchemaRepository, EntityRepository, etc.)
// See: internal/domain/service.go (RequestIdempotencyStore, UnitOfWork)
//
// Ports that span multiple domains or are purely infrastructure-related
// (e.g., EventBus) live in this package.
