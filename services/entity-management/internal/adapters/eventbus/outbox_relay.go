package eventbus

import (
	"context"
	"fmt"
	"log/slog"
	"math"
	"strings"
	"sync"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/trace"

	"entity-management/internal/domain"
	"entity-management/internal/ports"
)

const relayTracerName = "eventbus.outboxrelay"

const (
	DefaultPollInterval = 500 * time.Millisecond
	DefaultMaxRetries   = 3
	DefaultBatchSize    = 50
	BackoffBase         = 1 * time.Second
	BackoffMultiplier   = 2.0
)

// subjectMapping maps domain event types to NATS-compatible subjects.
var subjectMapping = map[string]string{
	"entity.schema.defined": "entitymanagement.schema.defined",
	"entity.schema.updated": "entitymanagement.schema.updated",
	"entity.created":        "entitymanagement.entity.created",
	"entity.updated":        "entitymanagement.entity.updated",
	"entity.deleted":        "entitymanagement.entity.deleted",
	"entity.soft_deleted":   "entitymanagement.entity.soft_deleted",
	"entity.hard_deleted":   "entitymanagement.entity.hard_deleted",
	"entity.restored":       "entitymanagement.entity.restored",
	"entity.read":           "entitymanagement.entity.read",
}

// solaceTopicMapping maps domain event types to Solace PubSub+ topics
// following the pattern: entity/{EventName}/v1.
var solaceTopicMapping = map[string]string{
	"entity.schema.defined": "entity/EntitySchemaDefined/v1",
	"entity.schema.updated": "entity/EntitySchemaUpdated/v1",
	"entity.created":        "entity/EntityCreated/v1",
	"entity.updated":        "entity/EntityUpdated/v1",
	"entity.deleted":        "entity/EntityDeleted/v1",
	"entity.soft_deleted":   "entity/EntitySoftDeleted/v1",
	"entity.hard_deleted":   "entity/EntityHardDeleted/v1",
	"entity.restored":       "entity/EntityRestored/v1",
	"entity.read":           "entity/EntityRead/v1",
}

// eventTypeToTopic converts a domain event type (e.g. "entity.created")
// to the Solace topic format "entity/EntityCreated/v1".
func eventTypeToTopic(eventType string) string {
	if t, ok := solaceTopicMapping[eventType]; ok {
		return t
	}
	// Fallback: attempt to convert generically.
	parts := strings.SplitN(eventType, ".", 2)
	if len(parts) == 2 {
		capitalized := strings.ToUpper(parts[1][:1]) + parts[1][1:]
		return parts[0] + "/" + capitalized + "/v1"
	}
	return eventType
}

func resolveSubject(eventType string) (string, bool) {
	subject, ok := subjectMapping[eventType]
	return subject, ok
}

// TopicResolver selects the topic format based on the event bus type.
type TopicResolver func(eventType string) string

// SolaceTopicResolver returns a TopicResolver that generates Solace-formatted
// topics (entity/EntityCreated/v1).
func SolaceTopicResolver() TopicResolver {
	return eventTypeToTopic
}

// NATSTopicResolver returns a TopicResolver that generates NATS-formatted
// subjects (entitymanagement.entity.created).
func NATSTopicResolver() TopicResolver {
	return func(eventType string) string {
		if s, ok := resolveSubject(eventType); ok {
			return s
		}
		return ""
	}
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

// WithTopicResolver sets a custom topic resolver for the relay.
func WithTopicResolver(resolver TopicResolver) OutboxRelayOption {
	return func(r *OutboxRelay) { r.topicResolver = resolver }
}

type OutboxRelay struct {
	outbox           domain.OutboxRepository
	bus              ports.EventBus
	logger           *slog.Logger
	pollInterval     time.Duration
	maxRetries       int
	batchSize        int
	topicResolver    TopicResolver
	publishedCounter metric.Int64Counter
	failedCounter    metric.Int64Counter
	retryCounter     metric.Int64Counter
	mu               sync.Mutex
	closed           bool
}

func NewOutboxRelay(
	outbox domain.OutboxRepository,
	bus ports.EventBus,
	logger *slog.Logger,
	opts ...OutboxRelayOption,
) *OutboxRelay {
	r := &OutboxRelay{
		outbox:        outbox,
		bus:           bus,
		logger:        logger.With("component", "OutboxRelay"),
		pollInterval:  DefaultPollInterval,
		maxRetries:    DefaultMaxRetries,
		batchSize:     DefaultBatchSize,
		topicResolver: NATSTopicResolver(), // default to NATS for backwards compat
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
	// Resolve the topic using the configured resolver.
	topic := r.topicResolver(event.EventType)
	if topic == "" {
		r.logger.WarnContext(ctx, "unknown event type, marking as failed",
			"event_id", event.ID, "event_type", event.EventType)
		r.outbox.MarkFailed(ctx, event.ID, fmt.Errorf("unknown event type: %s", event.EventType))
		if r.failedCounter != nil {
			r.failedCounter.Add(ctx, 1, metric.WithAttributes(
				attribute.String("event_type", event.EventType),
				attribute.String("reason", "unknown_type"),
			))
		}
		return
	}

	// Propagate the current OpenTelemetry trace context into the envelope.
	span := trace.SpanFromContext(ctx)
	traceID := span.SpanContext().TraceID().String()

	envType := event.EventType
	if resolvedType, ok := resolveSubject(event.EventType); ok {
		envType = resolvedType
	}

	envelope := &ports.Envelope{
		CloudEventAttributes: ports.CloudEventAttributes{
			SpecVersion:     "1.0",
			Type:            envType,
			Source:          "/entity-manager",
			ID:              event.ID,
			Time:            event.CreatedAt,
			DataContentType: "application/json",
			Subject:         event.AggregateID,
			Extensions: map[string]string{
				"traceid": traceID,
				"version": "1",
			},
		},
		Data: event.Payload,
	}

	for attempt := 0; attempt <= r.maxRetries; attempt++ {
		if attempt > 0 {
			backoff := computeBackoff(attempt)
			r.logger.DebugContext(ctx, "retrying outbox event",
				"event_id", event.ID, "attempt", attempt, "backoff_ms", backoff.Milliseconds())
			if r.retryCounter != nil {
				r.retryCounter.Add(ctx, 1, metric.WithAttributes(
					attribute.String("event_type", event.EventType),
					attribute.Int("attempt", attempt),
				))
			}
			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff):
			}
		}

		if err := r.bus.Publish(ctx, topic, envelope); err != nil {
			r.logger.ErrorContext(ctx, "failed to publish outbox event",
				"event_id", event.ID,
				"event_type", event.EventType,
				"topic", topic,
				"attempt", attempt,
				"error", err,
			)
			if attempt == r.maxRetries {
				r.outbox.MarkFailed(ctx, event.ID, err)
				if r.failedCounter != nil {
					r.failedCounter.Add(ctx, 1, metric.WithAttributes(
						attribute.String("event_type", event.EventType),
						attribute.String("reason", "max_retries_exceeded"),
					))
				}
			}
			continue
		}

		r.outbox.MarkPublished(ctx, event.ID)
		if r.publishedCounter != nil {
			r.publishedCounter.Add(ctx, 1, metric.WithAttributes(
				attribute.String("event_type", event.EventType),
				attribute.Int("attempt", attempt),
			))
		}
		r.logger.DebugContext(ctx, "outbox event published",
			"event_id", event.ID,
			"event_type", event.EventType,
			"topic", topic,
			"attempt", attempt,
		)
		return
	}
}

// computeBackoff calculates the exponential backoff duration for a given
// retry attempt. Uses the formula: base * multiplier^(attempt-1).
func computeBackoff(attempt int) time.Duration {
	if attempt <= 0 {
		return 0
	}
	return BackoffBase * time.Duration(math.Pow(BackoffMultiplier, float64(attempt-1)))
}
