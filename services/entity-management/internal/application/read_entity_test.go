package application

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"testing"
	"time"

	"entity-management/internal/domain"
)

// ---------------------------------------------------------------------------
// Fake ports for ReadEntityUseCase testing.
// ---------------------------------------------------------------------------

// fakeReadEntityRepo implements domain.EntityRepository in-memory for the
// read path only. Unused methods panic to catch accidental test coupling.
type fakeReadEntityRepo struct {
	mu       sync.RWMutex
	entities map[string]*domain.Entity
}

func newFakeReadEntityRepo() *fakeReadEntityRepo {
	return &fakeReadEntityRepo{entities: make(map[string]*domain.Entity)}
}

func (r *fakeReadEntityRepo) Save(_ context.Context, entity *domain.Entity) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.entities[entity.ID] = entity
	return nil
}

func (r *fakeReadEntityRepo) FindByID(_ context.Context, id string) (*domain.Entity, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, ok := r.entities[id]
	if !ok {
		return nil, domain.ErrEntityNotFound
	}
	return e, nil
}

func (r *fakeReadEntityRepo) Update(_ context.Context, _ string, _ domain.UpdateOperation) (*domain.Entity, error) {
	panic("not implemented for read tests")
}
func (r *fakeReadEntityRepo) UpdateStatus(_ context.Context, _ string, _ domain.EntityStatus) error {
	panic("not implemented for read tests")
}
func (r *fakeReadEntityRepo) FindBySchemaID(_ context.Context, _ string) ([]*domain.Entity, error) {
	panic("not implemented for read tests")
}
func (r *fakeReadEntityRepo) List(_ context.Context, _ domain.EntityFilter) ([]*domain.Entity, error) {
	panic("not implemented for read tests")
}
func (r *fakeReadEntityRepo) SoftDelete(_ context.Context, _ string, _ time.Time) error {
	panic("not implemented for read tests")
}
func (r *fakeReadEntityRepo) Restore(_ context.Context, _ string) error {
	panic("not implemented for read tests")
}
func (r *fakeReadEntityRepo) HardDelete(_ context.Context, _ string) error {
	panic("not implemented for read tests")
}
func (r *fakeReadEntityRepo) ListEntities(_ context.Context, _ domain.ListEntitiesParams) (*domain.PaginatedResult, error) {
	panic("not implemented for read tests")
}

// fakeReadEventPublisher records published domain events for assertion.
type fakeReadEventPublisher struct {
	mu     sync.Mutex
	events []domain.DomainEvent
}

func newFakeReadEventPublisher() *fakeReadEventPublisher {
	return &fakeReadEventPublisher{}
}

func (f *fakeReadEventPublisher) PublishSchemaDefined(_ context.Context, _ *domain.EntitySchemaDefined) error {
	return nil
}
func (f *fakeReadEventPublisher) PublishSchemaUpdated(_ context.Context, _ *domain.EntitySchemaUpdated) error {
	return nil
}
func (f *fakeReadEventPublisher) PublishEntityCreated(_ context.Context, _ *domain.EntityCreated) error {
	return nil
}
func (f *fakeReadEventPublisher) PublishEntityUpdated(_ context.Context, _ *domain.EntityUpdated) error {
	return nil
}
func (f *fakeReadEventPublisher) PublishEntityDeleted(_ context.Context, _ *domain.EntityDeleted) error {
	return nil
}
func (f *fakeReadEventPublisher) PublishEntityRead(_ context.Context, event *domain.EntityRead) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.events = append(f.events, event)
	return nil
}
func (f *fakeReadEventPublisher) PublishEntitySoftDeleted(_ context.Context, _ *domain.EntitySoftDeleted) error {
	return nil
}
func (f *fakeReadEventPublisher) PublishEntityHardDeleted(_ context.Context, _ *domain.EntityHardDeleted) error {
	return nil
}
func (f *fakeReadEventPublisher) PublishEntityRestored(_ context.Context, _ *domain.EntityRestored) error {
	return nil
}
func (f *fakeReadEventPublisher) PublishEntitiesQueried(_ context.Context, _ *domain.EntitiesQueried) error {
	return nil
}
func (f *fakeReadEventPublisher) PublishInvalidCursorProvided(_ context.Context, _ *domain.InvalidCursorProvided) error {
	return nil
}
func (f *fakeReadEventPublisher) PublishAppStarted(_ context.Context, _ *domain.AppStarted) error {
	return nil
}
func (f *fakeReadEventPublisher) PublishAppStartupFailed(_ context.Context, _ *domain.AppStartupFailed) error {
	return nil
}

func (f *fakeReadEventPublisher) Events() []domain.DomainEvent {
	f.mu.Lock()
	defer f.mu.Unlock()
	result := make([]domain.DomainEvent, len(f.events))
	copy(result, f.events)
	return result
}

func readTestLogger(t *testing.T) *slog.Logger {
	t.Helper()
	return slog.New(slog.DiscardHandler)
}

// ---------------------------------------------------------------------------
// Gherkin Scenario 1: Successful entity read
//
// Given an entity with ID "ent-abc-123" exists
// When  a GET /api/v1/entities/ent-abc-123 request is made
// Then  the full entity payload is returned (HTTP 200)
//   Including all attributes, schema_id, region, status, version,
//   created_at, updated_at
//   And an entitymanagement.entity.read domain event is published
//   (fire-and-forget, non-blocking)
// ---------------------------------------------------------------------------

func TestReadEntity_Success(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Now().UTC()
	entityID := "ent-abc-123"

	// Given an entity with ID "ent-abc-123" exists
	repo := newFakeReadEntityRepo()
	if err := repo.Save(ctx, &domain.Entity{
		ID:                entityID,
		SchemaID:          "sch-customer-v2",
		Name:              "Alice Wonderland",
		Type:              "customer",
		Region:            "eu-west-1",
		DataResidencyZone: domain.ZoneEUWest1,
		Status:            domain.EntityStatusActive,
		Version:           3,
		Attributes: map[string]any{
			"email":  "alice@example.com",
			"age":    float64(42),
			"status": "active",
		},
		Metadata: map[string]any{
			"source": "import-csv-2024",
		},
		CreatedAt: now.Add(-72 * time.Hour),
		UpdatedAt: now.Add(-1 * time.Hour),
	}); err != nil {
		t.Fatalf("save entity: %v", err)
	}

	eventPub := newFakeReadEventPublisher()
	uc := NewReadEntityUseCase(repo, eventPub, readTestLogger(t))

	// When a read request is made
	resp, err := uc.Execute(ctx, entityID)
	if err != nil {
		t.Fatalf("ReadEntityUseCase.Execute() failed: %v", err)
	}

	// Then the full entity payload is returned
	if resp == nil {
		t.Fatal("expected non-nil response")
	}

	// Including all fields: ID, SchemaID, Name, Type, Region, etc.
	if resp.ID != entityID {
		t.Errorf("expected ID %q, got %q", entityID, resp.ID)
	}
	if resp.SchemaID != "sch-customer-v2" {
		t.Errorf("expected SchemaID %q, got %q", "sch-customer-v2", resp.SchemaID)
	}
	if resp.Name != "Alice Wonderland" {
		t.Errorf("expected Name %q, got %q", "Alice Wonderland", resp.Name)
	}
	if resp.Type != "customer" {
		t.Errorf("expected Type %q, got %q", "customer", resp.Type)
	}
	if resp.Region != "eu-west-1" {
		t.Errorf("expected Region %q, got %q", "eu-west-1", resp.Region)
	}
	if resp.DataResidencyZone != string(domain.ZoneEUWest1) {
		t.Errorf("expected DataResidencyZone %q, got %q", string(domain.ZoneEUWest1), resp.DataResidencyZone)
	}
	if resp.Status != string(domain.EntityStatusActive) {
		t.Errorf("expected Status %q, got %q", string(domain.EntityStatusActive), resp.Status)
	}
	if resp.Version != 3 {
		t.Errorf("expected Version 3, got %d", resp.Version)
	}

	// Including created_at and updated_at
	expectedCreatedAt := now.Add(-72 * time.Hour)
	if !resp.CreatedAt.Equal(expectedCreatedAt) {
		t.Errorf("expected CreatedAt %v, got %v", expectedCreatedAt, resp.CreatedAt)
	}
	expectedUpdatedAt := now.Add(-1 * time.Hour)
	if !resp.UpdatedAt.Equal(expectedUpdatedAt) {
		t.Errorf("expected UpdatedAt %v, got %v", expectedUpdatedAt, resp.UpdatedAt)
	}

	// Including attributes
	if resp.Attributes == nil {
		t.Fatal("expected non-nil Attributes")
	}
	if email, ok := resp.Attributes["email"].(string); !ok || email != "alice@example.com" {
		t.Errorf("expected attribute email=%q, got %v", "alice@example.com", resp.Attributes["email"])
	}
	if age, ok := resp.Attributes["age"].(float64); !ok || age != 42 {
		t.Errorf("expected attribute age=42, got %v", resp.Attributes["age"])
	}

	// Including metadata
	if resp.Metadata == nil {
		t.Fatal("expected non-nil Metadata")
	}
	if source, ok := resp.Metadata["source"].(string); !ok || source != "import-csv-2024" {
		t.Errorf("expected metadata source=%q, got %v", "import-csv-2024", resp.Metadata["source"])
	}

	// And an entitymanagement.entity.read domain event is published
	events := eventPub.Events()
	if len(events) != 1 {
		t.Fatalf("expected 1 entity.read event published, got %d", len(events))
	}

	readEvent, ok := events[0].(*domain.EntityRead)
	if !ok {
		t.Fatalf("expected *domain.EntityRead event, got %T", events[0])
	}

	// Verify event fields
	if readEvent.EntityID != entityID {
		t.Errorf("expected event EntityID %q, got %q", entityID, readEvent.EntityID)
	}
	if readEvent.EntityName != "Alice Wonderland" {
		t.Errorf("expected event EntityName %q, got %q", "Alice Wonderland", readEvent.EntityName)
	}
	if readEvent.Region != "eu-west-1" {
		t.Errorf("expected event Region %q, got %q", "eu-west-1", readEvent.Region)
	}
	if readEvent.EventID == "" {
		t.Error("expected event EventID to be non-empty")
	}
	if readEvent.ReadAt.IsZero() {
		t.Error("expected event ReadAt to be set")
	}
}

// ---------------------------------------------------------------------------
// Gherkin Scenario 2: Entity not found
//
// Given an entity with ID "ent-nonexistent" does not exist
// When  a GET /api/v1/entities/ent-nonexistent request is made
// Then  HTTP 404 is returned with ErrorResponse
//   {code: "NOT_FOUND", message: "entity not found"}
//   And no entity.read event is published
// ---------------------------------------------------------------------------

func TestReadEntity_NotFound(t *testing.T) {
	t.Parallel()

	ctx := context.Background()

	// Given an empty repository (no entities exist)
	repo := newFakeReadEntityRepo()
	eventPub := newFakeReadEventPublisher()
	uc := NewReadEntityUseCase(repo, eventPub, readTestLogger(t))

	// When a read request is made for a nonexistent entity
	_, err := uc.Execute(ctx, "ent-nonexistent")

	// Then an error wrapping ErrEntityNotFound is returned
	if err == nil {
		t.Fatal("expected error for nonexistent entity, got nil")
	}
	if !errors.Is(err, domain.ErrEntityNotFound) {
		t.Errorf("expected ErrEntityNotFound, got %v", err)
	}

	// And no entity.read event is published
	events := eventPub.Events()
	if len(events) != 0 {
		t.Errorf("expected 0 events published for nonexistent entity, got %d", len(events))
	}
}

// ---------------------------------------------------------------------------
// Edge case: Empty entity ID
// ---------------------------------------------------------------------------

func TestReadEntity_EmptyID(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	repo := newFakeReadEntityRepo()
	eventPub := newFakeReadEventPublisher()
	uc := NewReadEntityUseCase(repo, eventPub, readTestLogger(t))

	// When a read request is made with an empty ID
	_, err := uc.Execute(ctx, "")

	// Then ErrEntityNotFound is returned (empty string not found in store)
	if err == nil {
		t.Fatal("expected error for empty ID, got nil")
	}
	if !errors.Is(err, domain.ErrEntityNotFound) {
		t.Errorf("expected ErrEntityNotFound, got %v", err)
	}

	// And no event is published
	if len(eventPub.Events()) != 0 {
		t.Error("expected no events published for empty ID")
	}
}

// ---------------------------------------------------------------------------
// Edge case: EventPublisher failure is non-fatal (fire-and-forget)
//
// The Gherkin specifies the entity.read event is "fire-and-forget, non-blocking".
// This means even if the event publisher fails, the read operation must still
// succeed and return the full entity payload.
// ---------------------------------------------------------------------------

func TestReadEntity_EventPublisherFailureIsNonFatal(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Now().UTC()
	entityID := "ent-fire-forget-001"

	// Given an entity exists
	repo := newFakeReadEntityRepo()
	if err := repo.Save(ctx, &domain.Entity{
		ID:                entityID,
		SchemaID:          "sch-test",
		Name:              "FireAndForget",
		Type:              "test",
		Region:            "us-east-1",
		DataResidencyZone: domain.ZoneUSEast1,
		Status:            domain.EntityStatusActive,
		Version:           1,
		CreatedAt:         now,
		UpdatedAt:         now,
	}); err != nil {
		t.Fatalf("save entity: %v", err)
	}

	// Use an event publisher that always fails
	failingPub := &failingEventPublisher{}
	uc := NewReadEntityUseCase(repo, failingPub, readTestLogger(t))

	// When the read executes
	resp, err := uc.Execute(ctx, entityID)

	// Then the read still succeeds (event failure is non-fatal)
	if err != nil {
		t.Fatalf("expected success even with event publisher failure, got: %v", err)
	}
	if resp == nil {
		t.Fatal("expected non-nil response despite event publisher failure")
	}
	if resp.ID != entityID {
		t.Errorf("expected ID %q, got %q", entityID, resp.ID)
	}

	// The event publish was attempted but failed
	if !failingPub.called {
		t.Error("expected PublishEntityRead to have been called")
	}
}

// failingEventPublisher simulates an event bus that fails to publish.
type failingEventPublisher struct {
	called bool
}

func (f *failingEventPublisher) PublishSchemaDefined(_ context.Context, _ *domain.EntitySchemaDefined) error {
	return errors.New("bus unavailable")
}
func (f *failingEventPublisher) PublishSchemaUpdated(_ context.Context, _ *domain.EntitySchemaUpdated) error {
	return errors.New("bus unavailable")
}
func (f *failingEventPublisher) PublishEntityCreated(_ context.Context, _ *domain.EntityCreated) error {
	return errors.New("bus unavailable")
}
func (f *failingEventPublisher) PublishEntityUpdated(_ context.Context, _ *domain.EntityUpdated) error {
	return errors.New("bus unavailable")
}
func (f *failingEventPublisher) PublishEntityDeleted(_ context.Context, _ *domain.EntityDeleted) error {
	return errors.New("bus unavailable")
}
func (f *failingEventPublisher) PublishEntityRead(_ context.Context, _ *domain.EntityRead) error {
	f.called = true
	return errors.New("nats: connection refused")
}
func (f *failingEventPublisher) PublishEntitySoftDeleted(_ context.Context, _ *domain.EntitySoftDeleted) error {
	return errors.New("bus unavailable")
}
func (f *failingEventPublisher) PublishEntityHardDeleted(_ context.Context, _ *domain.EntityHardDeleted) error {
	return errors.New("bus unavailable")
}
func (f *failingEventPublisher) PublishEntityRestored(_ context.Context, _ *domain.EntityRestored) error {
	return errors.New("bus unavailable")
}
func (f *failingEventPublisher) PublishEntitiesQueried(_ context.Context, _ *domain.EntitiesQueried) error {
	return errors.New("bus unavailable")
}
func (f *failingEventPublisher) PublishInvalidCursorProvided(_ context.Context, _ *domain.InvalidCursorProvided) error {
	return errors.New("bus unavailable")
}
func (f *failingEventPublisher) PublishAppStarted(_ context.Context, _ *domain.AppStarted) error {
	return errors.New("bus unavailable")
}
func (f *failingEventPublisher) PublishAppStartupFailed(_ context.Context, _ *domain.AppStartupFailed) error {
	return errors.New("bus unavailable")
}
