// Package natsbus implements the ports.EventBus interface using NATS.
package natsbus

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"github.com/nats-io/nats.go"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"

	"github.com/prodanlabs/region-resolver/internal/ports"
)

var tracer = otel.Tracer("natsbus")

// Compile-time interface check.
var _ ports.EventBus = (*Bus)(nil)

// Bus implements ports.EventBus using NATS.
type Bus struct {
	conn    *nats.Conn
	logger  *slog.Logger
	subs    []*nats.Subscription
}

// NewNATSEventBus creates a new NATS event bus connected to the given URL.
func NewNATSEventBus(url string, logger *slog.Logger) (*Bus, error) {
	nc, err := nats.Connect(url,
		nats.RetryOnFailedConnect(true),
		nats.MaxReconnects(10),
		nats.ReconnectWait(2*time.Second),
		nats.Name("region-resolver"),
	)
	if err != nil {
		return nil, fmt.Errorf("connect to NATS: %w", err)
	}

	logger.Info("connected to NATS", "url", url)

	return &Bus{
		conn:   nc,
		logger: logger,
		subs:   make([]*nats.Subscription, 0),
	}, nil
}

// Publish sends a CloudEvents envelope to NATS.
func (b *Bus) Publish(ctx context.Context, subject string, envelope *ports.Envelope) error {
	ctx, span := tracer.Start(ctx, "natsbus.Publish",
		trace.WithAttributes(
			attribute.String("subject", subject),
			attribute.String("event_type", envelope.Type),
			attribute.String("event_id", envelope.ID),
		),
	)
	defer span.End()

	data, err := json.Marshal(envelope)
	if err != nil {
		return fmt.Errorf("marshal envelope: %w", err)
	}

	if err := b.conn.Publish(subject, data); err != nil {
		span.RecordError(err)
		return fmt.Errorf("publish to NATS: %w", err)
	}

	b.logger.DebugContext(ctx, "event published",
		"subject", subject,
		"event_id", envelope.ID,
		"event_type", envelope.Type,
	)
	return nil
}

// Subscribe registers a handler for the given NATS subject.
func (b *Bus) Subscribe(ctx context.Context, subject string, handler ports.EventHandler) error {
	sub, err := b.conn.Subscribe(subject, func(msg *nats.Msg) {
		disp := handler(ctx, msg.Data)
		switch disp {
		case ports.Ack:
		case ports.Retry:
			if err := b.conn.Publish(msg.Reply, msg.Data); err != nil {
				b.logger.ErrorContext(ctx, "retry publish failed", "error", err)
			}
		case ports.BadRequest:
		}
	})
	if err != nil {
		return fmt.Errorf("subscribe to %s: %w", subject, err)
	}

	b.subs = append(b.subs, sub)
	b.logger.InfoContext(ctx, "subscribed to subject", "subject", subject)
	return nil
}

// Close gracefully shuts down the NATS connection.
func (b *Bus) Close() error {
	for _, sub := range b.subs {
		if err := sub.Unsubscribe(); err != nil {
			b.logger.Warn("unsubscribe error", "error", err)
		}
	}
	b.conn.Close()
	return nil
}

// NoopBus implements ports.EventBus with no-op operations for degraded mode.
type NoopBus struct {
	logger *slog.Logger
}

// NewNoopBus creates a no-op event bus for when NATS is unavailable.
func NewNoopBus(logger *slog.Logger) *NoopBus {
	return &NoopBus{logger: logger}
}

func (b *NoopBus) Publish(_ context.Context, subject string, envelope *ports.Envelope) error {
	b.logger.Debug("noop publish", "subject", subject, "event_id", envelope.ID)
	return nil
}

func (b *NoopBus) Subscribe(_ context.Context, subject string, _ ports.EventHandler) error {
	b.logger.Debug("noop subscribe", "subject", subject)
	return nil
}

func (b *NoopBus) Close() error {
	return nil
}
