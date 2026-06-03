package eventbus

import (
	"context"
	"fmt"
	"log/slog"
	"math"
	"sync"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"

	"entity-management/internal/domain"
	"entity-management/internal/ports"
)

const relayTracerName = "eventbus.outboxrelay"

const (
	DefaultPollInterval   = 500 * time.Millisecond
	DefaultMaxRetries     = 3
	DefaultBatchSize      = 50
	BackoffBase           = 1 * time.Second
	BackoffMultiplier     = 2.0
)

var subjectMapping = map[string]string{
	"entity.schema.defined":   "entitymanagement.schema.defined",
	"entity.schema.updated":   "entitymanagement.schema.updated",
	"entity.created":          "entitymanagement.entity.created",
	"entity.updated":          "entitymanagement.entity.updated",
	"entity.deleted":          "entitymanagement.entity.deleted",
	"entity.soft_deleted":     "entitymanagement.entity.soft_deleted",
	"entity.hard_deleted":     "entitymanagement.entity.hard_deleted",
	"entity.restored":         "entitymanagement.entity.restored",
	"entity.read":             "entitymanagement.entity.read",
}

func resolveSubject(eventType string) (string, bool) {
	subject, ok := subjectMapping[eventType]
	return subject, ok
}

type OutboxRelayOption func(*OutboxRelay)

func WithPollInterval(d time.Duration) OutboxRelayOption {
	return func(r *OutboxRelay) { r.pollInterval = d }
}

func WithMaxRetries(n int) OutboxRelayOption {
	return func(r *OutboxRelay) { r.maxRetries = n }
}

func WithBatchSize(n int) OutboxRelayOption {
	return func(r *OutboxRelay) { r.batchSize = n }
}

type OutboxRelay struct {
	outbox       domain.OutboxRepository
	bus          ports.EventBus
	logger       *slog.Logger
	pollInterval time.Duration
	maxRetries   int
	batchSize    int
	publishedCounter metric.Int64Counter
	failedCounter    metric.Int64Counter
	retryCounter     metric.Int64Counter
	mu     sync.Mutex
	closed bool
}

func NewOutboxRelay(
	outbox domain.OutboxRepository,
	bus ports.EventBus,
	logger *slog.Logger,
	opts ...OutboxRelayOption,
) *OutboxRelay {
	r := &OutboxRelay{
		outbox:       outbox,
		bus:          bus,
		logger:       logger.With("component", "OutboxRelay"),
		pollInterval: DefaultPollInterval,
		maxRetries:   DefaultMaxRetries,
		batchSize:    DefaultBatchSize,
	}
	for _, opt := range opts {
		opt(r)
	}
	r.initMetrics()
	return r
}

func (r *OutboxRelay) initMetrics() {
	meter := otel.Meter(relayTracerName)
	var err error
	r.publishedCounter, err = meter.Int64Counter("outbox.relay.events.published",
		metric.WithDescription("Total number of outbox events successfully published"),
		metric.WithUnit("{event}"),
	)
	if err != nil {
		r.logger.Warn("failed to create published counter", "error", err)
	}
	r.failedCounter, err = meter.Int64Counter("outbox.relay.events.failed",
		metric.WithDescription("Total number of outbox events that permanently failed"),
		metric.WithUnit("{event}"),
	)
	if err != nil {
		r.logger.Warn("failed to create failed counter", "error", err)
	}
	r.retryCounter, err = meter.Int64Counter("outbox.relay.events.retries",
		metric.WithDescription("Total number of outbox event retries"),
		metric.WithUnit("{event}"),
	)
	if err != nil {
		r.logger.Warn("failed to create retry counter", "error", err)
	}
}

func (r *OutboxRelay) Run(ctx context.Context) error {
	r.logger.InfoContext(ctx, "outbox relay starting")
	ticker := time.NewTicker(r.pollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			r.processBatch(ctx)
		}
	}
}

func (r *OutboxRelay) processBatch(ctx context.Context) {
	events, err := r.outbox.FetchPending(ctx, r.batchSize)
	if err != nil {
		r.logger.ErrorContext(ctx, "failed to fetch pending outbox events", "error", err)
		return
	}
	if len(events) == 0 {
		return
	}

	for _, event := range events {
		select {
		case <-ctx.Done():
			return
		default:
		}
		r.processEvent(ctx, event)
	}
}

func (r *OutboxRelay) processEvent(ctx context.Context, event *domain.OutboxEvent) {
	subject, ok := resolveSubject(event.EventType)
	if !ok {
		r.logger.WarnContext(ctx, "unknown event type, marking as failed",
			"event_id", event.ID, "event_type", event.EventType)
		r.outbox.MarkFailed(ctx, event.ID, fmt.Errorf("unknown event type: %s", event.EventType))
		return
	}

	for attempt := 0; attempt <= r.maxRetries; attempt++ {
		if attempt > 0 {
			backoff := computeBackoff(attempt)
			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff):
			}
		}

		if err := r.bus.Publish(ctx, subject, &ports.Envelope{
			CloudEventAttributes: ports.CloudEventAttributes{
				SpecVersion: "1.0", Type: subject, Source: "/entity-manager",
				ID: event.ID, Time: event.CreatedAt,
				DataContentType: "application/json", Subject: event.AggregateID,
			},
			Data: event.Payload,
		}); err != nil {
			r.logger.ErrorContext(ctx, "failed to publish outbox event",
				"event_id", event.ID, "attempt", attempt, "error", err)
			if attempt == r.maxRetries {
				r.outbox.MarkFailed(ctx, event.ID, err)
			}
			continue
		}

		r.outbox.MarkPublished(ctx, event.ID)
		return
	}
}

func computeBackoff(attempt int) time.Duration {
	if attempt <= 0 {
		return 0
	}
	return BackoffBase * time.Duration(math.Pow(BackoffMultiplier, float64(attempt-1)))
}
