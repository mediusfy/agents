// Package ports defines the EventBus interface and CloudEvents envelope types
// for the entity-management service.
//
// These are "secondary ports" (driven side) in Hexagonal Architecture terms.
package ports

import (
	"context"
	"time"

	"go.opentelemetry.io/otel/trace"
)

// CloudEventAttributes holds the standard CloudEvents specification attributes
// as defined by the CloudEvents 1.0 specification.
type CloudEventAttributes struct {
	SpecVersion     string            `json:"specversion"`
	Type            string            `json:"type"`
	Source          string            `json:"source"`
	ID              string            `json:"id"`
	Time            time.Time         `json:"time"`
	DataContentType string            `json:"datacontenttype"`
	Subject         string            `json:"subject,omitempty"`
	Extensions      map[string]string `json:"extensions,omitempty"`
}

// Envelope wraps a CloudEvents-compliant payload with its metadata.
// The Data field contains the original event payload as raw JSON bytes.
type Envelope struct {
	CloudEventAttributes
	Data []byte `json:"data"`
}

// NewEnvelope creates a CloudEvents envelope with the given attributes.
// It extracts the current OpenTelemetry trace ID from the context and
// injects it into the extensions map under the key "traceid".
func NewEnvelope(ctx context.Context, eventType, source, id, subject string, occurredAt time.Time, data []byte) *Envelope {
	ext := map[string]string{
		"version": "1",
	}

	// Inject the current OpenTelemetry trace ID into the CloudEvents envelope.
	if sc := trace.SpanContextFromContext(ctx); sc.IsValid() {
		ext["traceid"] = sc.TraceID().String()
	}

	return &Envelope{
		CloudEventAttributes: CloudEventAttributes{
			SpecVersion:     "1.0",
			Type:            eventType,
			Source:          source,
			ID:              id,
			Time:            occurredAt,
			DataContentType: "application/json",
			Subject:         subject,
			Extensions:      ext,
		},
		Data: data,
	}
}

// EnvelopeWithTrace is a convenience constructor that creates an Envelope and
// explicitly embeds the trace context from the supplied span context.
func EnvelopeWithTrace(sc trace.SpanContext, eventType, source, id, subject string, occurredAt time.Time, data []byte) *Envelope {
	ext := map[string]string{
		"version": "1",
	}
	if sc.IsValid() {
		ext["traceid"] = sc.TraceID().String()
	}

	return &Envelope{
		CloudEventAttributes: CloudEventAttributes{
			SpecVersion:     "1.0",
			Type:            eventType,
			Source:          source,
			ID:              id,
			Time:            occurredAt,
			DataContentType: "application/json",
			Subject:         subject,
			Extensions:      ext,
		},
		Data: data,
	}
}

// EventBus defines the interface for publishing and subscribing to events.
// Includes a Ping method for health checking (HEALTH-01).
type EventBus interface {
	Publish(ctx context.Context, subject string, envelope *Envelope) error
	Subscribe(ctx context.Context, subject string, handler EventHandler) error
	Ping(ctx context.Context) error
	Close() error
}

// Disposition represents the result of handling an event.
type Disposition int

const (
	Ack Disposition = iota
	Retry
	BadRequest
)

// EventHandler processes an event and returns a Disposition indicating
// whether the event was handled successfully (Ack), should be retried (Retry),
// or is invalid (BadRequest).
type EventHandler func(ctx context.Context, data []byte) Disposition
