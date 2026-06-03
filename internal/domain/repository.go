package domain

import "context"

// EntityRepository is a port consumed by the domain layer.
//
//go:generate moq -out ../../mocks/repository.go -pkg mocks . EntityRepository
type EntityRepository interface {
	// FindByID retrieves a single entity by primary key.
	// Returns nil, nil if no row exists.
	FindByID(ctx context.Context, id string) (*Entity, error)

	// Save persists a new entity row.
	Save(ctx context.Context, entity *Entity) error

	// Update persists changes to an existing entity using optimistic locking
	// on the Version field. Returns ErrConcurrentUpdate if the version
	// does not match the stored row.
	Update(ctx context.Context, entity *Entity) error

	// List returns a paginated slice of entities ordered by creation time
	// descending. Page is 1-indexed; Limit must be between 1 and 100.
	List(ctx context.Context, input ListInput) (*ListResult, error)
}
