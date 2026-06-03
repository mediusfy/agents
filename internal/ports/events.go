package ports

import (
	"context"

	cloudevents "github.com/cloudevents/sdk-go/v2/event"
)

// EventBus abstracts the outbound event publisher.
// Implementations must be idempotent on the deduplication key.
type EventBus interface {
	// Publish sends a CloudEvent to the message backbone.
	// The caller supplies a pre-built CloudEvents.Event with
	// Source, Type, Subject, ID (dedup key), and Data set.
	Publish(ctx context.Context, event cloudevents.Event) error

	// Close shuts down the underlying connection.
	Close() error
}

// OutboxPoller is an optional interface for services that
// need to flush the transactional outbox to the message bus.
type OutboxPoller interface {
	PollAndPublish(ctx context.Context) (int, error)
}
