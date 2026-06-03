package ports

import (
	"context"

	"entity-management/internal/domain"
)

// Repository defines the data-access boundary for entities.
// Implementations live in adapters/.
type Repository interface {
	// GetByID loads an entity by its primary key.
	// Returns domain.ErrNotFound when no row exists.
	GetByID(ctx context.Context, id string) (*domain.Entity, error)

	// HardDelete permanently removes a soft-deleted entity from the store
	// and writes a hard-deleted event to the transactional outbox.
	// The outbox entry is committed atomically with the DELETE.
	HardDelete(ctx context.Context, entity *domain.Entity) error
}
