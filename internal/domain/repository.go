package domain

import (
	"context"
	"time"
)

// EntityRepository defines the storage contract for Entity aggregates.
type EntityRepository interface {
	GetByID(ctx context.Context, id string) (*Entity, error)
	Update(ctx context.Context, entity *Entity) error
	Close(ctx context.Context) error
}

// OutboxRepository defines the contract for the transactional outbox.
type OutboxRepository interface {
	Insert(ctx context.Context, msg *OutboxMessage) error
	FetchPending(ctx context.Context, batchSize int) ([]OutboxMessage, error)
	MarkPublished(ctx context.Context, ids []string) error
	DeletePublished(ctx context.Context, olderThan time.Duration) error
}
