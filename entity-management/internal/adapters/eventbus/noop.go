package eventbus

import (
	"context"
	"log/slog"

	"entity-management/internal/ports"
)

var _ ports.EventBus = (*NoopBus)(nil)

type NoopBus struct {
	logger *slog.Logger
}

func NewNoopBus(logger *slog.Logger) *NoopBus {
	return &NoopBus{
		logger: logger.With("adapter", "eventbus.NoopBus", "mode", "degraded"),
	}
}

func (b *NoopBus) Publish(_ context.Context, subject string, envelope *ports.Envelope) error {
	b.logger.Debug("noop event bus: publishing event",
		"subject", subject,
		"event_id", envelope.ID,
		"event_type", envelope.Type,
	)
	return nil
}

func (b *NoopBus) Subscribe(_ context.Context, subject string, _ ports.EventHandler) error {
	b.logger.Debug("noop event bus: subscribe (no-op)", "subject", subject)
	return nil
}

func (b *NoopBus) Close() error {
	b.logger.Debug("noop event bus: close")
	return nil
}
