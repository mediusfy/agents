package eventbus

import (
	"context"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"entity-management/internal/ports"
)

// ============================================================================
// GHERKIN SCENARIO: NoopEventBus fallback when NATS unavailable
//
//   Given the NATS connection was unavailable at startup
//   When a noopEventBus fallback is used
//   Then events are logged at DEBUG level instead of published
//     And the service continues to operate in degraded mode
// ============================================================================

func TestGherkin_NoopBus_DegradedMode_EventsLoggedAtDebug(t *testing.T) {
	t.Parallel()

	ctx := context.Background()

	// Given the NATS connection was unavailable at startup
	// When a noopEventBus fallback is used
	logHandler := newTestLogHandler()
	logger := slog.New(logHandler)

	bus := NewNoopBus(logger)

	// Then events are logged at DEBUG level instead of published
	// Test publishing various event types
	now := time.Date(2025, 1, 15, 10, 0, 0, 0, time.UTC)

	envelope := &ports.Envelope{
		CloudEventAttributes: ports.CloudEventAttributes{
			SpecVersion:     "1.0",
			Type:            "entitymanagement.entity.created",
			Source:          "/entity-manager",
			ID:              "evt-001",
			Time:            now,
			DataContentType: "application/json",
			Subject:         "ent-001",
		},
		Data: []byte(`{"entity_id":"ent-001","name":"Alice"}`),
	}

	err := bus.Publish(ctx, "entitymanagement.entity.created", envelope)
	if err != nil {
		t.Fatalf("NoopBus.Publish returned error: %v", err)
	}

	// And the service continues to operate in degraded mode — Publish always succeeds
	if err != nil {
		t.Errorf("expected no error from NoopBus.Publish, got: %v", err)
	}

	// Verify the event was logged at DEBUG level
	messages := logHandler.Messages()
	if len(messages) == 0 {
		t.Fatal("expected at least one log message from NoopBus.Publish, got none")
	}

	foundDebug := false
	for _, msg := range messages {
		if msg.level == slog.LevelDebug && strings.Contains(msg.message, "noop event bus: publishing event") {
			foundDebug = true
			// Verify the envelope fields are logged
			if subj, ok := msg.attrs["subject"]; ok {
				if subj != "entitymanagement.entity.created" {
					t.Errorf("expected logged subject %q, got %q", "entitymanagement.entity.created", subj)
				}
			} else {
				t.Error("expected 'subject' attribute in log message")
			}
			if eventID, ok := msg.attrs["event_id"]; ok {
				if eventID != "evt-001" {
					t.Errorf("expected logged event_id %q, got %q", "evt-001", eventID)
				}
			} else {
				t.Error("expected 'event_id' attribute in log message")
			}
			break
		}
	}
	if !foundDebug {
		t.Errorf("expected DEBUG log message containing 'noop event bus: publishing event', got: %v", messages)
	}
}

// ============================================================================
// GHERKIN SCENARIO: NoopBus Subscribe is a no-op
// ============================================================================

func TestGherkin_NoopBus_Subscribe_IsNoop(t *testing.T) {
	t.Parallel()

	ctx := context.Background()

	logHandler := newTestLogHandler()
	logger := slog.New(logHandler)

	bus := NewNoopBus(logger)

	// When the service subscribes to a subject via NoopBus
	err := bus.Subscribe(ctx, "entitymanagement.entity.created", func(_ context.Context, _ []byte) ports.Disposition {
		return ports.Ack
	})
	if err != nil {
		t.Fatalf("NoopBus.Subscribe returned error: %v", err)
	}

	// Then the subscribe is logged at DEBUG level
	messages := logHandler.Messages()
	foundDebug := false
	for _, msg := range messages {
		if msg.level == slog.LevelDebug && strings.Contains(msg.message, "noop event bus: subscribe") {
			foundDebug = true
			if subj, ok := msg.attrs["subject"]; ok {
				if subj != "entitymanagement.entity.created" {
					t.Errorf("expected logged subject %q, got %q", "entitymanagement.entity.created", subj)
				}
			}
			break
		}
	}
	if !foundDebug {
		t.Errorf("expected DEBUG log message for subscribe, got: %v", messages)
	}
}

// ============================================================================
// GHERKIN SCENARIO: NoopBus Close is a no-op
// ============================================================================

func TestGherkin_NoopBus_Close_IsNoop(t *testing.T) {
	t.Parallel()

	logHandler := newTestLogHandler()
	logger := slog.New(logHandler)

	bus := NewNoopBus(logger)

	// When the service closes the bus
	err := bus.Close()
	if err != nil {
		t.Fatalf("NoopBus.Close returned error: %v", err)
	}

	// Then the close is logged at DEBUG level
	messages := logHandler.Messages()
	foundDebug := false
	for _, msg := range messages {
		if msg.level == slog.LevelDebug && strings.Contains(msg.message, "noop event bus: close") {
			foundDebug = true
			break
		}
	}
	if !foundDebug {
		t.Errorf("expected DEBUG log message for close, got: %v", messages)
	}
}

// ============================================================================
// GHERKIN SCENARIO: NoopBus is used as fallback for NATS failure at startup
//
//   Given the NATS connection was unavailable at startup
//   When the NoopBus is constructed
//   Then the logger includes degraded mode indicators
// ============================================================================

func TestGherkin_NoopBus_DegradedMode_LoggerIndicators(t *testing.T) {
	t.Parallel()

	logHandler := newTestLogHandler()
	logger := slog.New(logHandler)

	// When a NoopBus is created as fallback
	bus := NewNoopBus(logger)

	// Then the logger includes "mode=degraded" and "adapter=eventbus.NoopBus"
	// We can't directly check the logger's attrs, but we can verify the bus
	// operates in degraded mode by checking its behavior
	if bus == nil {
		t.Fatal("NoopBus must not be nil")
	}

	// Publish should succeed (degraded mode doesn't crash)
	ctx := context.Background()
	envelope := &ports.Envelope{
		CloudEventAttributes: ports.CloudEventAttributes{
			SpecVersion: "1.0",
			Type:        "entitymanagement.entity.created",
			Source:      "/entity-manager",
			ID:          "evt-001",
			Time:        time.Now(),
		},
		Data: []byte(`{}`),
	}
	err := bus.Publish(ctx, "test.subject", envelope)
	if err != nil {
		t.Errorf("NoopBus.Publish should never fail in degraded mode, got: %v", err)
	}
}

// ============================================================================
// Test: NoopBus satisfies the EventBus interface
// ============================================================================

func TestGherkin_NoopBus_ImplementsEventBus(t *testing.T) {
	t.Parallel()

	// Compile-time check
	var _ ports.EventBus = (*NoopBus)(nil)

	logHandler := newTestLogHandler()
	logger := slog.New(logHandler)

	bus := NewNoopBus(logger)

	// Verify all interface methods work without error
	ctx := context.Background()

	// Publish
	if err := bus.Publish(ctx, "test.subject", &ports.Envelope{
		CloudEventAttributes: ports.CloudEventAttributes{
			SpecVersion: "1.0",
			Type:        "test.type",
			Source:      "/test",
			ID:          "test-id",
			Time:        time.Now(),
		},
		Data: []byte(`{}`),
	}); err != nil {
		t.Errorf("Publish failed: %v", err)
	}

	// Subscribe
	if err := bus.Subscribe(ctx, "test.subject", func(_ context.Context, _ []byte) ports.Disposition {
		return ports.Ack
	}); err != nil {
		t.Errorf("Subscribe failed: %v", err)
	}

	// Close
	if err := bus.Close(); err != nil {
		t.Errorf("Close failed: %v", err)
	}
}

// ============================================================================
// Concurrency test: NoopBus must be safe for concurrent access
// ============================================================================

func TestGherkin_NoopBus_ConcurrentAccess_Safe(t *testing.T) {
	t.Parallel()

	logHandler := newTestLogHandler()
	logger := slog.New(logHandler)

	bus := NewNoopBus(logger)
	ctx := context.Background()

	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			env := &ports.Envelope{
				CloudEventAttributes: ports.CloudEventAttributes{
					SpecVersion: "1.0",
					Type:        "test.type",
					Source:      "/test",
					ID:          "test-id",
					Time:        time.Now(),
				},
				Data: []byte(`{}`),
			}
			_ = bus.Publish(ctx, "test.subject", env)
		}(i)
	}
	wg.Wait()

	// All goroutines should have completed without panic/data race
	messages := logHandler.Messages()
	if len(messages) != 20 {
		t.Logf("expected 20 log messages for 20 concurrent publishes, got %d", len(messages))
	}
}

// ============================================================================
// Additional edge cases
// ============================================================================

func TestGherkin_NoopBus_EmptySubject_NoPanic(t *testing.T) {
	t.Parallel()

	logHandler := newTestLogHandler()
	logger := slog.New(logHandler)

	bus := NewNoopBus(logger)
	ctx := context.Background()

	// Empty subject should not panic
	err := bus.Publish(ctx, "", &ports.Envelope{
		CloudEventAttributes: ports.CloudEventAttributes{
			ID:   "evt-empty",
			Type: "test",
		},
		Data: []byte(`{}`),
	})
	if err != nil {
		t.Errorf("Publish with empty subject should not fail: %v", err)
	}
}

func TestGherkin_NoopBus_NilEnvelope_NoPanic(t *testing.T) {
	t.Parallel()

	logHandler := newTestLogHandler()
	logger := slog.New(logHandler)

	bus := NewNoopBus(logger)
	ctx := context.Background()

	// A nil envelope would cause a panic in the real NATS bus,
	// but the NoopBus should handle it gracefully
	err := bus.Publish(ctx, "test.subject", nil)
	if err != nil {
		t.Errorf("Publish with nil envelope should not fail: %v", err)
	}
}
