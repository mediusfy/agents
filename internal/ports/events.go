package ports

import "context"

// EventBus defines the port for publishing events.
// Implementations must support at-least-once delivery
// and include a deduplication key for idempotent consumption.
type EventBus interface {
	Publish(ctx context.Context, event any) error
	Close() error
}
