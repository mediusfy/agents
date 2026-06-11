package eventbus

import (
	"context"
	"errors"
	"log/slog"

	"entity-management/internal/ports"
)

var _ ports.EventBus = (*NoopBus)(nil)

// ErrNoopDegraded is returned by NoopBus.Ping to signal that the event bus
// is operating in degraded mode. The health checker uses this to report
// "degraded" status rather than "down".
var ErrNoopDegraded = errors.New("noop: degraded")

type NoopBus struct {
	logger *slog.Logger
}

func NewNoopBus(logger *slog.Logger) *NoopBus {
	return &NoopBus{
		logger: logger.With("adapter", "eventbus.NoopBus", "mode", "degraded"),
	}
}

func (b *NoopBus) Publish(_ context.Context, subject string, envelope *ports.Envelope) error {
	if envelope == nil {
		b.logger.Debug("noop event bus: publishing nil envelope", "subject", subject)
		return nil
	}
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

// Ping returns ErrNoopDegraded to indicate the event bus is running in
// degraded (noop) mode. The health checker uses this sentinel error to
// report a "degraded" status rather than "down".
func (b *NoopBus) Ping(_ context.Context) error {
	return ErrNoopDegraded
}

func (b *NoopBus) Close() error {
	b.logger.Debug("noop event bus: close")
	return nil
}
