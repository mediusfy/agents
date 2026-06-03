package eventbus

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/drewjocham/agents/internal/domain"
	"github.com/drewjocham/agents/internal/ports"
)

const entitySubject = "entity.v1.events"

// generateID produces a random hex string for message deduplication.
func generateID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// MemoryEventBus is an in-memory implementation of ports.EventBus.
// In production, replace with NATS (github.com/nats-io/nats.go).
type MemoryEventBus struct {
	mu       sync.Mutex
	messages []message
}

type message struct {
	ID        string
	Subject   string
	Payload   []byte
	Timestamp time.Time
}

// NewMemoryEventBus returns a ready-to-use in-memory event bus.
func NewMemoryEventBus() *MemoryEventBus {
	return &MemoryEventBus{}
}

// Publish marshals the event to JSON and stores it in memory.
func (b *MemoryEventBus) Publish(ctx context.Context, event any) error {
	data, err := json.Marshal(event)
	if err != nil {
		return fmt.Errorf("mem-eventbus: marshal: %w", err)
	}

	msg := message{
		ID:        generateID(),
		Subject:   entitySubject,
		Payload:   data,
		Timestamp: time.Now().UTC(),
	}

	b.mu.Lock()
	b.messages = append(b.messages, msg)
	b.mu.Unlock()

	slog.DebugContext(ctx, "event published (in-memory)",
		"subject", entitySubject,
		"msg_id", msg.ID,
	)
	return nil
}

// Close is a no-op for the in-memory implementation.
func (b *MemoryEventBus) Close() error {
	return nil
}

// Messages returns a copy of all published messages (for testing).
func (b *MemoryEventBus) Messages() []message {
	b.mu.Lock()
	defer b.mu.Unlock()
	cp := make([]message, len(b.messages))
	copy(cp, b.messages)
	return cp
}

// compile-time checks
var _ ports.EventBus = (*MemoryEventBus)(nil)
var _ domain.EventBus = (*MemoryEventBus)(nil)
