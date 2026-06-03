// Package ports defines the secondary port interfaces that the domain layer
// depends upon. In Hexagonal Architecture, interfaces live at the consumer
// site; the domain package already defines EntityRepository and EventPublisher.
// This file adds CloudEvents envelope definitions and the EventBus abstraction
// for infrastructure-level message transport.
package ports

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"

	"github.com/prodanlabs/region-resolver/internal/domain"
)

const tracerName = "region-resolver.ports"

// CloudEventAttributes represents the mandatory attributes of a CloudEvents
// 1.0 specification message.
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

// Envelope wraps a domain event payload with CloudEvents metadata.
type Envelope struct {
	CloudEventAttributes
	Data json.RawMessage `json:"data"`
}

// NewEntityCreatedEnvelope creates a CloudEvents envelope for a
// region.resolver.entity.created event.
func NewEntityCreatedEnvelope(event *domain.EntityCreated) *Envelope {
	data, _ := json.Marshal(map[string]any{
		"entity_id":            event.EntityID,
		"entity_name":          event.EntityName,
		"region":               event.Region,
		"data_residency_zone":  event.DataResidencyZone,
	})
	return &Envelope{
		CloudEventAttributes: CloudEventAttributes{
			SpecVersion:     "1.0",
			Type:            event.EventName(),
			Source:          "/region-resolver",
			ID:              event.EventID,
			Time:            event.OccurredAt,
			DataContentType: "application/json",
			Subject:         event.EntityID,
			Extensions: map[string]string{
				"entityname":        event.EntityName,
				"region":            event.Region,
				"dataresidencyzone": string(event.DataResidencyZone),
			},
		},
		Data: data,
	}
}

// NewEntityUpdatedEnvelope creates a CloudEvents envelope for a
// region.resolver.entity.updated event.
func NewEntityUpdatedEnvelope(event *domain.EntityUpdated) *Envelope {
	data, _ := json.Marshal(map[string]any{
		"entity_id":         event.EntityID,
		"entity_name":       event.EntityName,
		"previous_version":  event.PreviousVersion,
		"new_version":       event.NewVersion,
		"changed_fields":    event.ChangedFields,
	})
	ext := map[string]string{
		"entityname": event.EntityName,
		"prevver":    fmt.Sprintf("%d", event.PreviousVersion),
		"newver":     fmt.Sprintf("%d", event.NewVersion),
	}
	return &Envelope{
		CloudEventAttributes: CloudEventAttributes{
			SpecVersion:     "1.0",
			Type:            event.EventName(),
			Source:          "/region-resolver",
			ID:              event.EventID,
			Time:            event.OccurredAt,
			DataContentType: "application/json",
			Subject:         event.EntityID,
			Extensions:      ext,
		},
		Data: data,
	}
}

// NewEntityDeletedEnvelope creates a CloudEvents envelope for a
// region.resolver.entity.deleted event.
func NewEntityDeletedEnvelope(event *domain.EntityDeleted) *Envelope {
	data, _ := json.Marshal(map[string]any{
		"entity_id":   event.EntityID,
		"entity_name": event.EntityName,
		"region":      event.Region,
	})
	return &Envelope{
		CloudEventAttributes: CloudEventAttributes{
			SpecVersion:     "1.0",
			Type:            event.EventName(),
			Source:          "/region-resolver",
			ID:              event.EventID,
			Time:            event.OccurredAt,
			DataContentType: "application/json",
			Subject:         event.EntityID,
			Extensions: map[string]string{
				"entityname": event.EntityName,
				"region":     event.Region,
			},
		},
		Data: data,
	}
}

// Disposition represents the result of processing an event message.
type Disposition int

const (
	// Ack indicates the message was processed successfully.
	Ack Disposition = iota
	// Retry indicates the message should be retried later.
	Retry
	// BadRequest indicates the message is malformed and should be dropped.
	BadRequest
)

// EventHandler processes a raw event message and returns a disposition.
type EventHandler func(ctx context.Context, data []byte) Disposition

// EventBus defines the interface for publishing and subscribing to
// CloudEvents-compliant messages over a message broker.
type EventBus interface {
	Publish(ctx context.Context, subject string, envelope *Envelope) error
	Subscribe(ctx context.Context, subject string, handler EventHandler) error
	Close() error
}

// EventPublisherAdapter implements domain.EventPublisher by wrapping an
// EventBus and emitting CloudEvents envelopes.
type EventPublisherAdapter struct {
	bus      EventBus
	source   string
	tracer   trace.Tracer
}

// NewEventPublisherAdapter creates a new EventPublisherAdapter.
func NewEventPublisherAdapter(bus EventBus, source string) *EventPublisherAdapter {
	return &EventPublisherAdapter{
		bus:    bus,
		source: source,
		tracer: otel.Tracer(tracerName),
	}
}

func (a *EventPublisherAdapter) PublishEntityCreated(ctx context.Context, event *domain.EntityCreated) error {
	ctx, span := a.tracer.Start(ctx, "ports.EventPublisherAdapter.PublishEntityCreated",
		trace.WithAttributes(
			attribute.String("event_id", event.EventID),
			attribute.String("entity_id", event.EntityID),
			attribute.String("region", event.Region),
			attribute.String("data_residency_zone", string(event.DataResidencyZone)),
		),
	)
	defer span.End()

	env := NewEntityCreatedEnvelope(event)
	return a.bus.Publish(ctx, "region.resolver.entity.created", env)
}

func (a *EventPublisherAdapter) PublishEntityUpdated(ctx context.Context, event *domain.EntityUpdated) error {
	ctx, span := a.tracer.Start(ctx, "ports.EventPublisherAdapter.PublishEntityUpdated",
		trace.WithAttributes(
			attribute.String("event_id", event.EventID),
			attribute.String("entity_id", event.EntityID),
			attribute.Int("prev_version", event.PreviousVersion),
			attribute.Int("new_version", event.NewVersion),
		),
	)
	defer span.End()

	env := NewEntityUpdatedEnvelope(event)
	return a.bus.Publish(ctx, "region.resolver.entity.updated", env)
}

func (a *EventPublisherAdapter) PublishEntityDeleted(ctx context.Context, event *domain.EntityDeleted) error {
	ctx, span := a.tracer.Start(ctx, "ports.EventPublisherAdapter.PublishEntityDeleted",
		trace.WithAttributes(
			attribute.String("event_id", event.EventID),
			attribute.String("entity_id", event.EntityID),
			attribute.String("region", event.Region),
		),
	)
	defer span.End()

	env := NewEntityDeletedEnvelope(event)
	return a.bus.Publish(ctx, "region.resolver.entity.deleted", env)
}
