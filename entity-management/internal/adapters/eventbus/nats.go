package eventbus

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

	"entity-management/internal/ports"
)

var tracer = otel.Tracer("eventbus.nats")

var _ ports.EventBus = (*NATSBus)(nil)

type NATSBus struct {
	conn    *nats.Conn
	logger  *slog.Logger
	subs    []*nats.Subscription
	closeCh chan struct{}
}

func NewNATSEventBus(url string, logger *slog.Logger) (*NATSBus, error) {
	nc, err := nats.Connect(url,
		nats.RetryOnFailedConnect(true),
		nats.MaxReconnects(10),
		nats.ReconnectWait(2*time.Second),
		nats.Name("entity-manager"),
	)
	if err != nil {
		return nil, fmt.Errorf("connect to NATS: %w", err)
	}

	logger.Info("connected to NATS", "url", url)

	return &NATSBus{
		conn:    nc,
		logger:  logger,
		subs:    make([]*nats.Subscription, 0),
		closeCh: make(chan struct{}),
	}, nil
}

func (b *NATSBus) Publish(ctx context.Context, subject string, envelope *ports.Envelope) error {
	ctx, span := tracer.Start(ctx, "eventbus.Publish",
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

	return nil
}

func (b *NATSBus) Subscribe(ctx context.Context, subject string, handler ports.EventHandler) error {
	sub, err := b.conn.Subscribe(subject, func(msg *nats.Msg) {
		disp := handler(ctx, msg.Data)
		switch disp {
		case ports.Ack:
		case ports.Retry:
			b.conn.Publish(msg.Reply, msg.Data)
		case ports.BadRequest:
		}
	})
	if err != nil {
		return fmt.Errorf("subscribe to %s: %w", subject, err)
	}
	b.subs = append(b.subs, sub)
	return nil
}

func (b *NATSBus) Close() error {
	close(b.closeCh)
	for _, sub := range b.subs {
		sub.Unsubscribe()
	}
	b.conn.Close()
	return nil
}
