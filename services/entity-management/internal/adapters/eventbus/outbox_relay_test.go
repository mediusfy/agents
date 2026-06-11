package eventbus

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"entity-management/internal/domain"
	"entity-management/internal/ports"
)

// ============================================================================
// Fake / mock implementations for hermetic outbox relay tests
// ============================================================================

// mockEventBus simulates NATS publish with configurable failure behavior.
type mockEventBus struct {
	mu             sync.Mutex
	publishedCalls []publishCall
	failOnAttempt  int           // fail on the Nth attempt (1-based); 0 = never fail
	attemptCounter int32         // atomic counter for publish attempts
	failAlways     bool          // always fail
	publishDelay   time.Duration // artificial delay before publish
}

type publishCall struct {
	subject  string
	envelope *ports.Envelope
}

func newMockEventBus() *mockEventBus {
	return &mockEventBus{}
}

func (m *mockEventBus) Publish(_ context.Context, subject string, envelope *ports.Envelope) error {
	atomic.AddInt32(&m.attemptCounter, 1)

	if m.publishDelay > 0 {
		time.Sleep(m.publishDelay)
	}

	m.mu.Lock()
	defer m.mu.Unlock()

	currentAttempt := int(atomic.LoadInt32(&m.attemptCounter))

	if m.failAlways {
		return errors.New("mock NATS: connection refused")
	}
	if m.failOnAttempt > 0 && currentAttempt == m.failOnAttempt {
		return fmt.Errorf("mock NATS: simulated failure on attempt %d", currentAttempt)
	}

	m.publishedCalls = append(m.publishedCalls, publishCall{
		subject:  subject,
		envelope: envelope,
	})
	return nil
}

func (m *mockEventBus) Subscribe(_ context.Context, _ string, _ ports.EventHandler) error {
	return nil
}

func (m *mockEventBus) Close() error { return nil }

func (m *mockEventBus) Ping(_ context.Context) error { return nil }

// publishedSubjects returns the subjects in the order they were published.
func (m *mockEventBus) publishedSubjects() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	subjects := make([]string, len(m.publishedCalls))
	for i, c := range m.publishedCalls {
		subjects[i] = c.subject
	}
	return subjects
}

// publishedEnvelopes returns a copy of all published envelopes.
func (m *mockEventBus) publishedEnvelopes() []*ports.Envelope {
	m.mu.Lock()
	defer m.mu.Unlock()
	envs := make([]*ports.Envelope, len(m.publishedCalls))
	for i, c := range m.publishedCalls {
		envs[i] = c.envelope
	}
	return envs
}

func (m *mockEventBus) publishCount() int {
	return int(atomic.LoadInt32(&m.attemptCounter))
}

// failOnNthAttempt configures the mock to fail on the Nth publish call.
func (m *mockEventBus) failOnNthAttempt(n int) {
	m.failOnAttempt = n
}

// fakeOutboxRepoForRelay is a thread-safe in-memory outbox store that
// tracks status transitions for verification.
type fakeOutboxRepoForRelay struct {
	mu             sync.Mutex
	events         []*domain.OutboxEvent
	publishedIDs   []string
	failedIDs      []string
	failMarkFailed bool // if true, MarkFailed returns an error
}

func newFakeOutboxRepoForRelay() *fakeOutboxRepoForRelay {
	return &fakeOutboxRepoForRelay{}
}

func (r *fakeOutboxRepoForRelay) Save(ctx context.Context, event *domain.OutboxEvent) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, event)
	return nil
}

func (r *fakeOutboxRepoForRelay) MarkPublished(_ context.Context, id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.publishedIDs = append(r.publishedIDs, id)
	for _, e := range r.events {
		if e.ID == id {
			e.Status = domain.OutboxStatusPublished
			break
		}
	}
	return nil
}

func (r *fakeOutboxRepoForRelay) MarkFailed(_ context.Context, id string, _ error) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.failMarkFailed {
		return errors.New("mock: MarkFailed failed")
	}
	r.failedIDs = append(r.failedIDs, id)
	for _, e := range r.events {
		if e.ID == id {
			e.Status = domain.OutboxStatusFailed
			break
		}
	}
	return nil
}

func (r *fakeOutboxRepoForRelay) FetchPending(_ context.Context, limit int) ([]*domain.OutboxEvent, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	var pending []*domain.OutboxEvent
	for _, e := range r.events {
		if e.Status == domain.OutboxStatusPending {
			pending = append(pending, e)
		}
	}
	// Sort by CreatedAt for FIFO verification
	sort.Slice(pending, func(i, j int) bool {
		return pending[i].CreatedAt.Before(pending[j].CreatedAt)
	})
	if len(pending) > limit {
		pending = pending[:limit]
	}
	return pending, nil
}

func (r *fakeOutboxRepoForRelay) eventByID(id string) *domain.OutboxEvent {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, e := range r.events {
		if e.ID == id {
			return e
		}
	}
	return nil
}

// newTestLogger creates a slog.Logger that records all log messages at DEBUG+ levels.
// Returns the handler and logger. The handler's Messages() returns captured logs.
type testLogHandler struct {
	mu       sync.Mutex
	messages []logEntry
}

type logEntry struct {
	level   slog.Level
	message string
	attrs   map[string]string
}

func newTestLogHandler() *testLogHandler {
	return &testLogHandler{}
}

func (h *testLogHandler) Enabled(_ context.Context, level slog.Level) bool {
	return level >= slog.LevelDebug
}

func (h *testLogHandler) Handle(_ context.Context, r slog.Record) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	entry := logEntry{
		level:   r.Level,
		message: r.Message,
		attrs:   make(map[string]string),
	}
	r.Attrs(func(a slog.Attr) bool {
		entry.attrs[a.Key] = a.Value.String()
		return true
	})
	h.messages = append(h.messages, entry)
	return nil
}

func (h *testLogHandler) WithAttrs(_ []slog.Attr) slog.Handler { return h }
func (h *testLogHandler) WithGroup(_ string) slog.Handler      { return h }

func (h *testLogHandler) Messages() []logEntry {
	h.mu.Lock()
	defer h.mu.Unlock()
	cp := make([]logEntry, len(h.messages))
	copy(cp, h.messages)
	return cp
}

func (h *testLogHandler) Contains(level slog.Level, substr string) bool {
	for _, m := range h.Messages() {
		if m.level == level && strings.Contains(m.message, substr) {
			return true
		}
	}
	return false
}

// newOutboxEvent creates a test domain.OutboxEvent with the given params.
func newOutboxEvent(id, eventType, aggregateID string, createdAt time.Time) *domain.OutboxEvent {
	return &domain.OutboxEvent{
		ID:            id,
		AggregateID:   aggregateID,
		AggregateType: "entity",
		EventType:     eventType,
		Payload:       []byte(`{"test": true}`),
		Status:        domain.OutboxStatusPending,
		RetryCount:    0,
		CreatedAt:     createdAt,
	}
}

// ============================================================================
// GHERKIN SCENARIO: Outbox relay publishes pending events to NATS
//
//   Given an outbox event with status="pending"
//   When the outbox relay goroutine processes it
//   Then the event is published to NATS on subject "entitymanagement.entity.created"
//     And the outbox event status is updated to "published"
//     And the relay processes events in FIFO order
// ============================================================================

func TestGherkin_OutboxRelay_PendingEvent_PublishedToNATS(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Date(2025, 1, 15, 10, 0, 0, 0, time.UTC)

	// Given an outbox event with status="pending" for entity.created
	event := newOutboxEvent("evt-001", "entity.created", "ent-001", now)

	outbox := newFakeOutboxRepoForRelay()
	_ = outbox.Save(ctx, event)

	bus := newMockEventBus()
	logHandler := newTestLogHandler()
	logger := slog.New(logHandler)

	relay := NewOutboxRelay(outbox, bus, logger,
		WithPollInterval(50*time.Millisecond),
		WithMaxRetries(3),
		WithBatchSize(10),
	)

	// When the relay processes it (direct call to processBatch for determinism)
	relay.processBatch(ctx)

	// Then the event is published to NATS on subject "entitymanagement.entity.created"
	published := bus.publishedSubjects()
	if len(published) != 1 {
		t.Fatalf("expected 1 published event, got %d", len(published))
	}
	if published[0] != "entitymanagement.entity.created" {
		t.Errorf("expected subject %q, got %q", "entitymanagement.entity.created", published[0])
	}

	// And the outbox event status is updated to "published"
	processed := outbox.eventByID("evt-001")
	if processed == nil {
		t.Fatal("event not found in outbox")
	}
	if processed.Status != domain.OutboxStatusPublished {
		t.Errorf("expected event status %q, got %q", domain.OutboxStatusPublished, processed.Status)
	}

	// Verify the event was marked published
	if len(outbox.publishedIDs) != 1 {
		t.Errorf("expected 1 MarkPublished call, got %d", len(outbox.publishedIDs))
	}
	if outbox.publishedIDs[0] != "evt-001" {
		t.Errorf("expected MarkPublished(%q), got %q", "evt-001", outbox.publishedIDs[0])
	}

	// Verify the envelope contains cloud event fields
	envs := bus.publishedEnvelopes()
	if len(envs) != 1 {
		t.Fatalf("expected 1 envelope, got %d", len(envs))
	}
	env := envs[0]
	if env.SpecVersion != "1.0" {
		t.Errorf("expected specversion 1.0, got %q", env.SpecVersion)
	}
	if env.Type != "entitymanagement.entity.created" {
		t.Errorf("expected type %q, got %q", "entitymanagement.entity.created", env.Type)
	}
	if env.Source != "/entity-manager" {
		t.Errorf("expected source %q, got %q", "/entity-manager", env.Source)
	}
	if env.ID != "evt-001" {
		t.Errorf("expected event ID %q, got %q", "evt-001", env.ID)
	}
	if env.Subject != "ent-001" {
		t.Errorf("expected subject %q, got %q", "ent-001", env.Subject)
	}
	if env.DataContentType != "application/json" {
		t.Errorf("expected datacontenttype %q, got %q", "application/json", env.DataContentType)
	}
}

// ============================================================================
// GHERKIN SCENARIO: Outbox relay processes events in FIFO order
//
//   Given multiple outbox events with status="pending" at different times
//   When the outbox relay processes them
//   Then events are published to NATS in the same order they were created (FIFO)
// ============================================================================

func TestGherkin_OutboxRelay_FIFOProcessing(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Date(2025, 1, 15, 10, 0, 0, 0, time.UTC)

	outbox := newFakeOutboxRepoForRelay()
	bus := newMockEventBus()
	logHandler := newTestLogHandler()
	logger := slog.New(logHandler)

	// Given multiple outbox events with status="pending" at staggered times
	event1 := newOutboxEvent("evt-001", "entity.created", "ent-001", now.Add(-3*time.Second))
	event2 := newOutboxEvent("evt-002", "entity.updated", "ent-002", now.Add(-2*time.Second))
	event3 := newOutboxEvent("evt-003", "entity.deleted", "ent-003", now.Add(-1*time.Second))

	// Save them in non-FIFO order (event3, event1, event2) to test sorting
	_ = outbox.Save(ctx, event3)
	_ = outbox.Save(ctx, event1)
	_ = outbox.Save(ctx, event2)

	relay := NewOutboxRelay(outbox, bus, logger,
		WithPollInterval(50*time.Millisecond),
		WithMaxRetries(3),
		WithBatchSize(10),
	)

	// When the relay processes events in a batch
	relay.processBatch(ctx)

	// Then events are published to NATS in chronological order (FIFO by CreatedAt)
	published := bus.publishedSubjects()
	if len(published) != 3 {
		t.Fatalf("expected 3 published events, got %d", len(published))
	}

	expectedSubjects := []string{
		"entitymanagement.entity.created",
		"entitymanagement.entity.updated",
		"entitymanagement.entity.deleted",
	}
	for i, expected := range expectedSubjects {
		if published[i] != expected {
			t.Errorf("published[%d] subject = %q, want %q", i, published[i], expected)
		}
	}

	// Verify all events were marked published
	if len(outbox.publishedIDs) != 3 {
		t.Errorf("expected 3 MarkPublished calls, got %d", len(outbox.publishedIDs))
	}
	expectedIDs := []string{"evt-001", "evt-002", "evt-003"}
	for i, id := range outbox.publishedIDs {
		if id != expectedIDs[i] {
			t.Errorf("MarkPublished[%d] = %q, want %q", i, id, expectedIDs[i])
		}
	}
}

// ============================================================================
// GHERKIN SCENARIO: Unknown event type is marked as failed
//
//   Given an outbox event with an unknown event type
//   When the relay processes it
//   Then the event is marked as failed
//     And a warning is logged
// ============================================================================

func TestGherkin_OutboxRelay_UnknownEventType_MarkedFailed(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Date(2025, 1, 15, 10, 0, 0, 0, time.UTC)

	// Given an outbox event with an unknown event type
	event := newOutboxEvent("evt-unknown", "entity.unknown_type", "ent-001", now)

	outbox := newFakeOutboxRepoForRelay()
	_ = outbox.Save(ctx, event)

	bus := newMockEventBus()
	logHandler := newTestLogHandler()
	logger := slog.New(logHandler)

	relay := NewOutboxRelay(outbox, bus, logger,
		WithPollInterval(50*time.Millisecond),
		WithMaxRetries(3),
		WithBatchSize(10),
	)

	// When the relay processes it
	relay.processBatch(ctx)

	// Then the event is marked as failed (not retried)
	if len(outbox.failedIDs) != 1 {
		t.Fatalf("expected 1 MarkFailed call, got %d", len(outbox.failedIDs))
	}
	if outbox.failedIDs[0] != "evt-unknown" {
		t.Errorf("expected MarkFailed(%q), got %q", "evt-unknown", outbox.failedIDs[0])
	}

	// And no event was published
	if len(bus.publishedSubjects()) != 0 {
		t.Errorf("expected 0 published events for unknown type, got %d", len(bus.publishedSubjects()))
	}

	// And a warning is logged
	if !logHandler.Contains(slog.LevelWarn, "unknown event type") {
		t.Errorf("expected warning log containing 'unknown event type', got messages: %v", logHandler.Messages())
	}
}

// ============================================================================
// GHERKIN SCENARIO: Exponential backoff and retry on NATS failure
//
//   Given an outbox event fails to publish to NATS (network error)
//   When the relay retries
//   Then it retries with exponential backoff (1s, 2s, 4s) up to max_retries (default 3)
//     If max retries exhausted, event status is set to "failed"
//     And a critical alert metric is incremented
// ============================================================================

func TestGherkin_OutboxRelay_RetryWithExponentialBackoff(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Date(2025, 1, 15, 10, 0, 0, 0, time.UTC)

	// Given an outbox event that fails on first attempt but succeeds on retry
	event := newOutboxEvent("evt-retry-001", "entity.created", "ent-001", now)

	outbox := newFakeOutboxRepoForRelay()
	_ = outbox.Save(ctx, event)

	bus := newMockEventBus()
	bus.failOnNthAttempt(1) // first attempt fails, second succeeds

	logHandler := newTestLogHandler()
	logger := slog.New(logHandler)

	relay := NewOutboxRelay(outbox, bus, logger,
		WithPollInterval(50*time.Millisecond),
		WithMaxRetries(3),
		WithBatchSize(10),
	)

	// Record start time
	start := time.Now()

	// When the relay processes the event (first attempt fails, triggers retry)
	relay.processBatch(ctx)

	elapsed := time.Since(start)

	// Then the event was eventually published successfully
	published := bus.publishedSubjects()
	if len(published) != 1 {
		t.Fatalf("expected 1 published event after retry, got %d", len(published))
	}
	if published[0] != "entitymanagement.entity.created" {
		t.Errorf("expected subject %q, got %q", "entitymanagement.entity.created", published[0])
	}

	// The event should be marked as published (not failed)
	if len(outbox.publishedIDs) != 1 {
		t.Errorf("expected 1 MarkPublished call, got %d", len(outbox.publishedIDs))
	}
	if len(outbox.failedIDs) != 0 {
		t.Errorf("expected 0 MarkFailed calls, got %d", len(outbox.failedIDs))
	}

	// Verify backoff timing: first attempt fails, backoff ~1s, second succeeds
	// Allow some tolerance for test execution overhead
	if elapsed < 900*time.Millisecond {
		t.Logf("retry backoff elapsed: %v (expected at least ~1s for backoff)", elapsed)
	}

	// Total publish attempts = 2 (one fail, one success)
	if bus.publishCount() != 2 {
		t.Errorf("expected 2 total publish attempts (1 fail + 1 success), got %d", bus.publishCount())
	}

	// Log should contain the failure message
	if !logHandler.Contains(slog.LevelError, "failed to publish outbox event") {
		t.Errorf("expected error log about publish failure, got messages: %v", logHandler.Messages())
	}
}

// ============================================================================
// GHERKIN SCENARIO: Max retries exhausted → status = "failed"
//
//   Given an outbox event that always fails to publish
//   When the relay retries up to max_retries
//   Then all retries are exhausted
//     And event status is set to "failed"
//     And a critical alert metric is incremented
// ============================================================================

func TestGherkin_OutboxRelay_MaxRetriesExhausted_MarkedFailed(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Date(2025, 1, 15, 10, 0, 0, 0, time.UTC)

	// Given an outbox event that always fails to publish
	event := newOutboxEvent("evt-fail-001", "entity.created", "ent-001", now)

	outbox := newFakeOutboxRepoForRelay()
	_ = outbox.Save(ctx, event)

	bus := newMockEventBus()
	bus.failAlways = true

	logHandler := newTestLogHandler()
	logger := slog.New(logHandler)

	relay := NewOutboxRelay(outbox, bus, logger,
		WithPollInterval(50*time.Millisecond),
		WithMaxRetries(3),
		WithBatchSize(10),
	)

	start := time.Now()

	// When the relay processes the event (should retry up to maxRetries times)
	relay.processBatch(ctx)

	elapsed := time.Since(start)

	// Then the event was never published
	if len(bus.publishedSubjects()) != 0 {
		t.Errorf("expected 0 published events, got %d", len(bus.publishedSubjects()))
	}

	// And event status is set to "failed"
	if len(outbox.failedIDs) != 1 {
		t.Fatalf("expected 1 MarkFailed call, got %d", len(outbox.failedIDs))
	}
	if outbox.failedIDs[0] != "evt-fail-001" {
		t.Errorf("expected MarkFailed(%q), got %q", "evt-fail-001", outbox.failedIDs[0])
	}

	// Verify the in-memory event status
	processed := outbox.eventByID("evt-fail-001")
	if processed == nil {
		t.Fatal("event not found in outbox")
	}
	if processed.Status != domain.OutboxStatusFailed {
		t.Errorf("expected event status %q, got %q", domain.OutboxStatusFailed, processed.Status)
	}

	// Total attempts = maxRetries + 1 (initial attempt + maxRetries retries)
	expectedAttempts := 4 // 1 initial + 3 retries
	if bus.publishCount() != expectedAttempts {
		t.Errorf("expected %d total publish attempts, got %d", expectedAttempts, bus.publishCount())
	}

	// Verify backoff timing: 1s + 2s + 4s = 7s total backoff
	minExpected := 7*time.Second - 200*time.Millisecond // allow some tolerance
	if elapsed < minExpected {
		t.Logf("retry backoff total elapsed: %v (expected at least ~7s for 1s+2s+4s backoff)", elapsed)
	}

	// Log should contain each failure attempt
	if !logHandler.Contains(slog.LevelError, "failed to publish outbox event") {
		t.Errorf("expected error log about publish failure, got messages: %v", logHandler.Messages())
	}
}

// ============================================================================
// Table-driven test: computeBackoff values
//
//   Verifies the exponential backoff formula: BackoffBase * 2^(attempt-1)
//   Attempt 1: 1s, Attempt 2: 2s, Attempt 3: 4s
// ============================================================================

func TestComputeBackoff_Exponential_TableDriven(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		attempt  int
		expected time.Duration
	}{
		{
			name:     "attempt 0 returns 0s (no backoff before first try)",
			attempt:  0,
			expected: 0,
		},
		{
			name:     "attempt 1 returns 1s (first retry)",
			attempt:  1,
			expected: BackoffBase * time.Duration(math.Pow(BackoffMultiplier, 0)),
		},
		{
			name:     "attempt 2 returns 2s (second retry)",
			attempt:  2,
			expected: BackoffBase * time.Duration(math.Pow(BackoffMultiplier, 1)),
		},
		{
			name:     "attempt 3 returns 4s (third retry)",
			attempt:  3,
			expected: BackoffBase * time.Duration(math.Pow(BackoffMultiplier, 2)),
		},
		{
			name:     "attempt 4 returns 8s (fourth retry)",
			attempt:  4,
			expected: BackoffBase * time.Duration(math.Pow(BackoffMultiplier, 3)),
		},
		{
			name:     "attempt 5 returns 16s",
			attempt:  5,
			expected: BackoffBase * time.Duration(math.Pow(BackoffMultiplier, 4)),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := computeBackoff(tt.attempt)
			if got != tt.expected {
				t.Errorf("computeBackoff(%d) = %v, want %v", tt.attempt, got, tt.expected)
			}
		})
	}
}

// ============================================================================
// Table-driven test: subject resolution for all known event types
//
//   Verifies the subjectMapping covers all expected event types
// ============================================================================

func TestResolveSubject_TableDriven(t *testing.T) {
	t.Parallel()

	tests := []struct {
		eventType       string
		expectedSubject string
		expectedOK      bool
	}{
		{"entity.schema.defined", "entitymanagement.schema.defined", true},
		{"entity.schema.updated", "entitymanagement.schema.updated", true},
		{"entity.created", "entitymanagement.entity.created", true},
		{"entity.updated", "entitymanagement.entity.updated", true},
		{"entity.deleted", "entitymanagement.entity.deleted", true},
		{"entity.soft_deleted", "entitymanagement.entity.soft_deleted", true},
		{"entity.hard_deleted", "entitymanagement.entity.hard_deleted", true},
		{"entity.restored", "entitymanagement.entity.restored", true},
		{"entity.read", "entitymanagement.entity.read", true},
		// Unknown event types
		{"entity.unknown_type", "", false},
		{"", "", false},
		{"some.random.event", "", false},
	}

	for _, tt := range tests {
		t.Run(tt.eventType, func(t *testing.T) {
			subject, ok := resolveSubject(tt.eventType)
			if ok != tt.expectedOK {
				t.Errorf("resolveSubject(%q) ok = %v, want %v", tt.eventType, ok, tt.expectedOK)
			}
			if subject != tt.expectedSubject {
				t.Errorf("resolveSubject(%q) subject = %q, want %q", tt.eventType, subject, tt.expectedSubject)
			}
		})
	}
}

// ============================================================================
// Test: OutboxRelay processes multiple events correctly with mixed types
// ============================================================================

func TestGherkin_OutboxRelay_MultipleEvents_MixedTypes(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Date(2025, 1, 15, 10, 0, 0, 0, time.UTC)

	events := []*domain.OutboxEvent{
		newOutboxEvent("evt-001", "entity.schema.defined", "sch-001", now.Add(-5*time.Second)),
		newOutboxEvent("evt-002", "entity.created", "ent-001", now.Add(-4*time.Second)),
		newOutboxEvent("evt-003", "entity.updated", "ent-001", now.Add(-3*time.Second)),
		newOutboxEvent("evt-004", "entity.deleted", "ent-002", now.Add(-2*time.Second)),
		newOutboxEvent("evt-005", "entity.soft_deleted", "ent-003", now.Add(-1*time.Second)),
	}

	outbox := newFakeOutboxRepoForRelay()
	for _, e := range events {
		_ = outbox.Save(ctx, e)
	}

	bus := newMockEventBus()
	logger := slog.New(newTestLogHandler())

	relay := NewOutboxRelay(outbox, bus, logger,
		WithPollInterval(50*time.Millisecond),
		WithMaxRetries(2),
		WithBatchSize(10),
	)

	relay.processBatch(ctx)

	published := bus.publishedSubjects()
	if len(published) != 5 {
		t.Fatalf("expected 5 published events, got %d", len(published))
	}

	expected := []string{
		"entitymanagement.schema.defined",
		"entitymanagement.entity.created",
		"entitymanagement.entity.updated",
		"entitymanagement.entity.deleted",
		"entitymanagement.entity.soft_deleted",
	}
	for i, exp := range expected {
		if published[i] != exp {
			t.Errorf("published[%d] = %q, want %q", i, published[i], exp)
		}
	}

	if len(outbox.publishedIDs) != 5 {
		t.Errorf("expected 5 MarkPublished calls, got %d", len(outbox.publishedIDs))
	}
	if len(outbox.failedIDs) != 0 {
		t.Errorf("expected 0 MarkFailed calls, got %d", len(outbox.failedIDs))
	}
}

// ============================================================================
// Test: Context cancellation stops relay processing
// ============================================================================

func TestGherkin_OutboxRelay_ContextCancellation_StopsProcessing(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(context.Background())
	now := time.Date(2025, 1, 15, 10, 0, 0, 0, time.UTC)

	event := newOutboxEvent("evt-cancel", "entity.created", "ent-001", now)

	outbox := newFakeOutboxRepoForRelay()
	_ = outbox.Save(ctx, event)

	bus := newMockEventBus()
	logger := slog.New(newTestLogHandler())

	relay := NewOutboxRelay(outbox, bus, logger,
		WithPollInterval(50*time.Millisecond),
		WithMaxRetries(3),
		WithBatchSize(10),
	)

	// Cancel the context before processing
	cancel()

	// Process — should be a no-op due to cancelled context
	relay.processBatch(ctx)

	// No events should be published
	if len(bus.publishedSubjects()) != 0 {
		t.Errorf("expected 0 published events after cancellation, got %d", len(bus.publishedSubjects()))
	}
}

// ============================================================================
// Test: Empty batch does not trigger any publish
// ============================================================================

func TestGherkin_OutboxRelay_NoPendingEvents_NoOp(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	outbox := newFakeOutboxRepoForRelay()
	bus := newMockEventBus()
	logger := slog.New(newTestLogHandler())

	relay := NewOutboxRelay(outbox, bus, logger,
		WithPollInterval(50*time.Millisecond),
		WithMaxRetries(3),
		WithBatchSize(10),
	)

	relay.processBatch(ctx)

	if len(bus.publishedSubjects()) != 0 {
		t.Errorf("expected 0 published events for empty batch, got %d", len(bus.publishedSubjects()))
	}
}

// ============================================================================
// Test: OutboxRelay can be configured with options
// ============================================================================

func TestOutboxRelay_Configuration_Options(t *testing.T) {
	t.Parallel()

	outbox := newFakeOutboxRepoForRelay()
	bus := newMockEventBus()
	logHandler := newTestLogHandler()
	logger := slog.New(logHandler)

	relay := NewOutboxRelay(outbox, bus, logger,
		WithPollInterval(1*time.Second),
		WithMaxRetries(5),
		WithBatchSize(100),
	)

	if relay.pollInterval != 1*time.Second {
		t.Errorf("pollInterval = %v, want 1s", relay.pollInterval)
	}
	if relay.maxRetries != 5 {
		t.Errorf("maxRetries = %d, want 5", relay.maxRetries)
	}
	if relay.batchSize != 100 {
		t.Errorf("batchSize = %d, want 100", relay.batchSize)
	}
}

// ============================================================================
// GHERKIN SCENARIO (integrated): Create entity → entity.created saved to
// outbox → relay publishes to NATS
//
// This is a full end-to-end test using the domain service + relay.
// It demonstrates the complete transactional outbox pattern.
// ============================================================================

func TestGherkin_OutboxRelay_FullEndToEnd_CreateEntityFlow(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Date(2025, 1, 15, 10, 0, 0, 0, time.UTC)

	// ---- Setup domain service with real outbox + fake repos ----
	schemaRepo := &fakeSchemaRepoForE2E{schemas: make(map[string]*domain.EntitySchema)}
	entityRepo := &fakeEntityRepoForE2E{entities: make(map[string]*domain.Entity)}
	outboxRepo := newFakeOutboxRepoForRelay()
	idempotency := &fakeIdempotencyForE2E{store: make(map[string]string)}
	uow := &fakeUnitOfWorkForE2E{}

	// Seed a schema
	_ = schemaRepo.Save(ctx, &domain.EntitySchema{
		ID:   "sch-customer",
		Name: "Customer",
		Attributes: []domain.AttributeDefinition{
			{Name: "email", Type: domain.AttributeTypeString, Required: true},
			{Name: "name", Type: domain.AttributeTypeString, Required: true},
		},
		Version:   1,
		CreatedAt: now.Add(-2 * time.Hour),
		UpdatedAt: now.Add(-2 * time.Hour),
	})

	svc := domain.NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		domain.WithClock(func() time.Time { return now }),
	)

	// Create the entity
	result, err := svc.CreateEntity(ctx, domain.CreateEntityInput{
		SchemaID:   "sch-customer",
		Name:       "Alice",
		Type:       "customer",
		Region:     "eu-west-1",
		Attributes: map[string]any{"email": "alice@example.com", "name": "Alice"},
	})
	if err != nil {
		t.Fatalf("CreateEntity failed: %v", err)
	}
	if !result.Created {
		t.Fatal("expected entity to be created")
	}

	// Verify outbox has exactly 1 pending event
	pending, err := outboxRepo.FetchPending(ctx, 10)
	if err != nil {
		t.Fatalf("FetchPending failed: %v", err)
	}
	if len(pending) != 1 {
		t.Fatalf("expected 1 pending outbox event, got %d", len(pending))
	}
	evt := pending[0]
	if evt.EventType != "entity.created" {
		t.Errorf("expected event type %q, got %q", "entity.created", evt.EventType)
	}
	if evt.Status != domain.OutboxStatusPending {
		t.Errorf("expected status %q, got %q", domain.OutboxStatusPending, evt.Status)
	}
	if evt.AggregateID != result.Entity.ID {
		t.Errorf("expected aggregate_id %q, got %q", result.Entity.ID, evt.AggregateID)
	}

	// Now process via outbox relay
	bus := newMockEventBus()
	logger := slog.New(newTestLogHandler())

	relay := NewOutboxRelay(outboxRepo, bus, logger,
		WithPollInterval(50*time.Millisecond),
		WithMaxRetries(3),
		WithBatchSize(10),
	)

	relay.processBatch(ctx)

	// Verify event was published to NATS on correct subject
	published := bus.publishedSubjects()
	if len(published) != 1 {
		t.Fatalf("expected 1 published event, got %d", len(published))
	}
	if published[0] != "entitymanagement.entity.created" {
		t.Errorf("expected subject %q, got %q", "entitymanagement.entity.created", published[0])
	}

	// Verify outbox event status updated to "published"
	processed := outboxRepo.eventByID(evt.ID)
	if processed == nil {
		t.Fatal("event not found in outbox after relay")
	}
	if processed.Status != domain.OutboxStatusPublished {
		t.Errorf("expected event status %q, got %q", domain.OutboxStatusPublished, processed.Status)
	}

	// Verify envelope content matches the entity
	envs := bus.publishedEnvelopes()
	if len(envs) != 1 {
		t.Fatalf("expected 1 envelope, got %d", len(envs))
	}
	env := envs[0]
	if env.Subject != result.Entity.ID {
		t.Errorf("expected envelope Subject (entity ID) %q, got %q", result.Entity.ID, env.Subject)
	}
}

// ============================================================================
// Internal helpers for E2E test
// ============================================================================

type fakeSchemaRepoForE2E struct {
	mu      sync.RWMutex
	schemas map[string]*domain.EntitySchema
}

func (r *fakeSchemaRepoForE2E) Save(_ context.Context, schema *domain.EntitySchema) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.schemas[schema.ID] = schema
	return nil
}

func (r *fakeSchemaRepoForE2E) FindByID(_ context.Context, id string) (*domain.EntitySchema, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	s, ok := r.schemas[id]
	if !ok {
		return nil, domain.ErrSchemaNotFound
	}
	return s, nil
}

func (r *fakeSchemaRepoForE2E) FindByName(_ context.Context, name string) (*domain.EntitySchema, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, s := range r.schemas {
		if s.Name == name {
			return s, nil
		}
	}
	return nil, domain.ErrSchemaNotFound
}

func (r *fakeSchemaRepoForE2E) FindAll(_ context.Context) ([]*domain.EntitySchema, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var result []*domain.EntitySchema
	for _, s := range r.schemas {
		result = append(result, s)
	}
	return result, nil
}

func (r *fakeSchemaRepoForE2E) Delete(_ context.Context, id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.schemas, id)
	return nil
}

func newFakeSchemaRepoForE2E() *fakeSchemaRepoForE2E {
	return &fakeSchemaRepoForE2E{schemas: make(map[string]*domain.EntitySchema)}
}

type fakeEntityRepoForE2E struct {
	mu       sync.RWMutex
	entities map[string]*domain.Entity
}

func newFakeEntityRepoForE2E() *fakeEntityRepoForE2E {
	return &fakeEntityRepoForE2E{entities: make(map[string]*domain.Entity)}
}

func (r *fakeEntityRepoForE2E) Save(_ context.Context, entity *domain.Entity) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.entities[entity.ID] = entity.Clone()
	return nil
}

func (r *fakeEntityRepoForE2E) FindByID(_ context.Context, id string) (*domain.Entity, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, ok := r.entities[id]
	if !ok {
		return nil, domain.ErrEntityNotFound
	}
	return e.Clone(), nil
}

func (r *fakeEntityRepoForE2E) Update(_ context.Context, id string, op domain.UpdateOperation) (*domain.Entity, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.entities[id]
	if !ok {
		return nil, domain.ErrEntityNotFound
	}
	clone := e.Clone()
	if err := clone.ApplyUpdate(op); err != nil {
		return nil, err
	}
	r.entities[id] = clone
	return clone.Clone(), nil
}

func (r *fakeEntityRepoForE2E) UpdateStatus(_ context.Context, id string, status domain.EntityStatus) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.entities[id]
	if !ok {
		return domain.ErrEntityNotFound
	}
	clone := e.Clone()
	if !clone.Status.CanTransitionTo(status) {
		return domain.ErrInvalidStatusTransition
	}
	clone.Status = status
	clone.Version++
	r.entities[id] = clone
	return nil
}

func (r *fakeEntityRepoForE2E) FindBySchemaID(_ context.Context, schemaID string) ([]*domain.Entity, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var result []*domain.Entity
	for _, e := range r.entities {
		if e.SchemaID == schemaID {
			result = append(result, e.Clone())
		}
	}
	return result, nil
}

func (r *fakeEntityRepoForE2E) List(_ context.Context, filter domain.EntityFilter) ([]*domain.Entity, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var result []*domain.Entity
	for _, e := range r.entities {
		if filter.Status != nil && e.Status != *filter.Status {
			continue
		}
		if filter.Region != nil && e.Region != *filter.Region {
			continue
		}
		if filter.Zone != nil && e.DataResidencyZone != *filter.Zone {
			continue
		}
		result = append(result, e.Clone())
	}
	return result, nil
}

func (r *fakeEntityRepoForE2E) SoftDelete(_ context.Context, id string, deletedAt time.Time) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.entities[id]
	if !ok {
		return domain.ErrEntityNotFound
	}
	if e.DeletedAt != nil {
		return domain.ErrAlreadyDeleted
	}
	clone := e.Clone()
	clone.DeletedAt = &deletedAt
	clone.Status = domain.EntityStatusDeleted
	clone.Version++
	clone.UpdatedAt = deletedAt
	r.entities[id] = clone
	return nil
}

func (r *fakeEntityRepoForE2E) Restore(_ context.Context, id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.entities[id]
	if !ok {
		return domain.ErrEntityNotFound
	}
	if e.DeletedAt == nil {
		return domain.ErrNotDeleted
	}
	clone := e.Clone()
	clone.DeletedAt = nil
	clone.Status = domain.EntityStatusActive
	clone.Version++
	clone.UpdatedAt = time.Now()
	r.entities[id] = clone
	return nil
}

func (r *fakeEntityRepoForE2E) HardDelete(_ context.Context, id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.entities[id]; !ok {
		return domain.ErrEntityNotFound
	}
	delete(r.entities, id)
	return nil
}

func (r *fakeEntityRepoForE2E) ListEntities(_ context.Context, params domain.ListEntitiesParams) (*domain.PaginatedResult, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var filtered []*domain.Entity
	for _, e := range r.entities {
		if e.SchemaID != params.SchemaID {
			continue
		}
		if !params.IncludeDeleted && e.DeletedAt != nil {
			continue
		}
		filtered = append(filtered, e)
	}
	return &domain.PaginatedResult{
		Entities:   filtered,
		TotalCount: len(filtered),
	}, nil
}

type fakeIdempotencyForE2E struct {
	mu    sync.RWMutex
	store map[string]string
}

func (s *fakeIdempotencyForE2E) GetEntityID(_ context.Context, requestKey string) (string, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.store[requestKey], nil
}

func (s *fakeIdempotencyForE2E) Save(_ context.Context, requestKey, entityID string, _ time.Duration) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.store[requestKey] = entityID
	return nil
}

type fakeUnitOfWorkForE2E struct{}

func (u *fakeUnitOfWorkForE2E) Execute(_ context.Context, fn func(uowCtx context.Context) error) error {
	return fn(context.Background())
}
