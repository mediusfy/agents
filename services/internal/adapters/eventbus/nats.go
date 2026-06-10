package eventbus

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"github.com/drewjocham/agents/internal/domain"
	"github.com/drewjocham/agents/internal/ports"
	"github.com/nats-io/nats.go"
)

const entitySubject = "entity.v1.events"

// NATSBus implements the ports.EventBus interface using NATS.
type NATSBus struct {
	conn   *nats.Conn
	logger *slog.Logger
}

// NewNATSBus creates a new NATS-backed event bus.
func NewNATSBus(url string, logger *slog.Logger) (*NATSBus, error) {
	nc, err := nats.Connect(url,
		nats.RetryOnFailedConnect(true),
		nats.MaxReconnects(10),
		nats.ReconnectWait(2*time.Second),
		nats.Name("agents-service"),
	)
	if err != nil {
		return nil, fmt.Errorf("nats: connect: %w", err)
	}

	logger.Info("connected to NATS event bus", "url", url)

	return &NATSBus{
		conn:   nc,
		logger: logger,
	}, nil
}

// Publish serializes the event to JSON and publishes it to the NATS subject.
func (b *NATSBus) Publish(ctx context.Context, event any) error {
	data, err := json.Marshal(event)
	if err != nil {
		return fmt.Errorf("nats: marshal event: %w", err)
	}

	if err := b.conn.Publish(entitySubject, data); err != nil {
		return fmt.Errorf("nats: publish to subject %s: %w", entitySubject, err)
	}

	b.logger.DebugContext(ctx, "event published to NATS",
		"subject", entitySubject,
	)
	return nil
}

// Close gracefully shuts down the NATS connection.
func (b *NATSBus) Close() error {
	b.conn.Close()
	return nil
}

// compile-time checks
var _ ports.EventBus = (*NATSBus)(nil)
var _ domain.EventBus = (*NATSBus)(nil)
